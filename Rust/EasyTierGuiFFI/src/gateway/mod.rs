mod acme;
mod authority;
mod certificate_state;
mod config;
mod local_dns;
mod proxy;
mod status;
mod storage;
mod tls;

use std::{
    collections::{BTreeMap, BTreeSet},
    os::fd::AsRawFd,
    sync::Arc,
    time::Duration,
};

use arc_swap::ArcSwap;
use pingora::{
    apps::ServerApp,
    protocols::{GetSocketDigest, SocketDigest, Stream, l4},
    proxy::{HttpProxy, http_proxy},
    server::configuration::ServerConf,
};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use tokio::{
    net::{TcpListener, TcpStream},
    sync::{mpsc, oneshot, watch},
    task::{JoinHandle, JoinSet},
    time::{Instant, MissedTickBehavior, interval, sleep, timeout},
};
use zeroize::Zeroizing;

pub use config::{GatewayConfig, GatewaySecrets};
pub use status::GatewayStatusSnapshot;

use acme::{AcmeContext, AcmeJobOutput, DnsCredential};
use certificate_state::CertificateStateMachine;
use config::{
    DnsProviderKind, GATEWAY_SCHEMA_VERSION, ValidatedCertificate, ValidatedGatewayConfig,
};
use local_dns::{LocalDnsTable, SharedLocalDnsTable, bind_local_dns, spawn_local_dns};
use proxy::{
    GatewayProxy, Http01ChallengeStore, SharedRouteTable, build_route_table, spawn_route_resolver,
    spawn_route_resolvers,
};
use status::{
    CertificateAvailability, CertificateFailure, CertificateOperation, CertificateStatus,
    FailureKind, FailureSource, GatewayState, ListenerStatus, RouteServingMode, RuntimeIssue,
};
use storage::{
    CertificateScheduleJournal, CoordinatorJournal, GatewayStorage, PendingDnsCleanup,
    ProviderCooldownJournal,
};
use tls::{CertifiedMaterial, DynamicCertificateStore, build_tls_acceptor};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(30);
const CONNECTION_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);
const TLS_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const ACME_SCHEDULER_INTERVAL: Duration = Duration::from_secs(30);
const MAX_CONCURRENT_ACME_ORDERS: usize = 2;
const BACKGROUND_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);
const RETRY_DELAY_SECONDS: &[u64] = &[60, 300, 900, 3_600, 7_200, 14_400, 21_600];

pub struct GatewayHandle {
    commands: mpsc::Sender<GatewayCommand>,
    status: Arc<ArcSwap<GatewayStatusSnapshot>>,
    routes: Arc<SharedRouteTable>,
    certificates: Arc<DynamicCertificateStore>,
    http_only_domains: Arc<ArcSwap<BTreeSet<String>>>,
    #[cfg(test)]
    challenges: Arc<Http01ChallengeStore>,
}

impl GatewayHandle {
    pub async fn start(config_json: &str, secrets_json: &str) -> Result<Self, String> {
        install_rustls_crypto_provider()?;
        let config = GatewayConfig::parse(config_json)?.validate()?;
        let secrets = GatewaySecrets::parse(secrets_json)?;
        secrets.validate_references(&config)?;
        GatewayInstance::start(config, RuntimeSecrets::from_input(secrets)).await
    }

    pub async fn apply_config(
        &self,
        config_json: &str,
        secrets_json: Option<&str>,
    ) -> Result<(), String> {
        let config = GatewayConfig::parse(config_json)?.validate()?;
        let secrets = secrets_json
            .map(GatewaySecrets::parse)
            .transpose()?
            .map(|secrets| {
                secrets.validate_references(&config)?;
                Ok::<_, String>(RuntimeSecrets::from_input(secrets))
            })
            .transpose()?;
        self.command(|reply| GatewayCommand::Apply {
            config: Box::new(config),
            secrets,
            reply,
        })
        .await
    }

    pub async fn request_renewal(&self, certificate_id: Option<String>) -> Result<(), String> {
        self.command(|reply| GatewayCommand::Renew {
            certificate_id,
            reply,
        })
        .await
    }

    pub async fn stop(&self) -> Result<(), String> {
        self.command(|reply| GatewayCommand::Stop { reply }).await
    }

    pub fn status_json(&self) -> Result<String, String> {
        let mut status = self.status.load_full().as_ref().clone();
        status.routes = self.routes.statuses();
        let http_only_domains = self.http_only_domains.load();
        for route in &mut status.routes {
            route.serving_certificate_id = self.certificates.serving_certificate_id(&route.domain);
            route.serving_mode = if route.serving_certificate_id.is_some() {
                RouteServingMode::Https
            } else if http_only_domains.contains(&route.domain) {
                RouteServingMode::HttpOnly
            } else {
                RouteServingMode::Unavailable
            };
        }
        serde_json::to_string(&status)
            .map_err(|error| format!("failed to serialize gateway status: {error}"))
    }

    async fn command(
        &self,
        build: impl FnOnce(oneshot::Sender<Result<(), String>>) -> GatewayCommand,
    ) -> Result<(), String> {
        let (reply, response) = oneshot::channel();
        self.commands
            .send(build(reply))
            .await
            .map_err(|_| "gateway manager is not running".to_string())?;
        timeout(COMMAND_TIMEOUT, response)
            .await
            .map_err(|_| "gateway command timed out".to_string())?
            .map_err(|_| "gateway manager dropped the command response".to_string())?
    }
}

pub(crate) fn install_rustls_crypto_provider() -> Result<(), String> {
    if rustls::crypto::CryptoProvider::get_default().is_some() {
        return Ok(());
    }
    let _ = rustls::crypto::ring::default_provider().install_default();
    if rustls::crypto::CryptoProvider::get_default().is_some() {
        Ok(())
    } else {
        Err("failed to install the Rustls Ring crypto provider".to_string())
    }
}

pub fn stopped_status_json() -> Result<String, String> {
    serde_json::to_string(&GatewayStatusSnapshot::default())
        .map_err(|error| format!("failed to serialize gateway status: {error}"))
}

struct RuntimeSecrets {
    cloudflare: BTreeMap<String, Zeroizing<String>>,
    aliyun: BTreeMap<String, (Zeroizing<String>, Zeroizing<String>)>,
}

impl RuntimeSecrets {
    fn from_input(secrets: GatewaySecrets) -> Self {
        Self {
            cloudflare: secrets
                .cloudflare
                .into_iter()
                .map(|(id, secret)| (id, Zeroizing::new(secret.api_token)))
                .collect(),
            aliyun: secrets
                .aliyun
                .into_iter()
                .map(|(id, secret)| {
                    (
                        id,
                        (
                            Zeroizing::new(secret.access_key_id),
                            Zeroizing::new(secret.access_key_secret),
                        ),
                    )
                })
                .collect(),
        }
    }

    fn validate_references(&self, config: &ValidatedGatewayConfig) -> Result<(), String> {
        let _ = config;
        Ok(())
    }

    fn dns_credential(
        &self,
        provider: DnsProviderKind,
        credential_id: &str,
    ) -> Option<DnsCredential> {
        match provider {
            DnsProviderKind::Cloudflare => {
                self.cloudflare
                    .get(credential_id)
                    .map(|token| DnsCredential::Cloudflare {
                        api_token: Zeroizing::new(token.as_str().to_string()),
                    })
            }
            DnsProviderKind::Aliyun => {
                self.aliyun
                    .get(credential_id)
                    .map(|(access_key_id, access_key_secret)| DnsCredential::Aliyun {
                        access_key_id: Zeroizing::new(access_key_id.as_str().to_string()),
                        access_key_secret: Zeroizing::new(access_key_secret.as_str().to_string()),
                    })
            }
        }
    }

    fn dns_credential_for_cleanup(&self, cleanup: &PendingDnsCleanup) -> Option<DnsCredential> {
        let provider = match cleanup.provider.as_str() {
            "cloudflare" => DnsProviderKind::Cloudflare,
            "aliyun" => DnsProviderKind::Aliyun,
            _ => return None,
        };
        self.dns_credential(provider, &cleanup.credential_id)
    }
}

enum GatewayCommand {
    Apply {
        config: Box<ValidatedGatewayConfig>,
        secrets: Option<RuntimeSecrets>,
        reply: oneshot::Sender<Result<(), String>>,
    },
    Renew {
        certificate_id: Option<String>,
        reply: oneshot::Sender<Result<(), String>>,
    },
    Stop {
        reply: oneshot::Sender<Result<(), String>>,
    },
}

enum AcmeEvent {
    AttemptProgress {
        attempted_certificate: ValidatedCertificate,
        stage: status::CertificateStage,
    },
    JobFinished(AcmeJobOutput),
    ContactsSynced(Result<(), String>),
    RenewalSuggested {
        certificate_id: String,
        leaf_der: Vec<u8>,
        result: Result<Option<OffsetDateTime>, String>,
    },
    CleanupRetried {
        attempted: Vec<PendingDnsCleanup>,
        remaining: Vec<PendingDnsCleanup>,
        last_error: Option<String>,
    },
}

struct GatewayInstance {
    config: ValidatedGatewayConfig,
    secrets: RuntimeSecrets,
    storage: GatewayStorage,
    acme: Arc<AcmeContext>,
    acme_events: mpsc::UnboundedReceiver<AcmeEvent>,
    acme_event_sender: mpsc::UnboundedSender<AcmeEvent>,
    certificates: Arc<DynamicCertificateStore>,
    http_only_domains: Arc<ArcSwap<BTreeSet<String>>>,
    routes: Arc<SharedRouteTable>,
    local_dns: Arc<SharedLocalDnsTable>,
    proxy: Arc<HttpProxy<GatewayProxy>>,
    shutdown: watch::Sender<bool>,
    listener_tasks: Vec<JoinHandle<()>>,
    route_tasks: BTreeMap<String, JoinHandle<()>>,
    status: Arc<ArcSwap<GatewayStatusSnapshot>>,
    certificate_status: BTreeMap<String, CertificateStatus>,
    listener_status: ListenerStatus,
    queued_certificates: BTreeSet<String>,
    in_flight_certificates: BTreeSet<String>,
    ari_in_flight: BTreeSet<String>,
    renewal_at: BTreeMap<String, OffsetDateTime>,
    retry_attempts: BTreeMap<String, u32>,
    provider_cooldowns:
        BTreeMap<config::CertificateAuthorityKind, (OffsetDateTime, CertificateFailure)>,
    coordinator_journal: CoordinatorJournal,
    pending_cleanups: Vec<PendingDnsCleanup>,
    cleanup_in_flight: bool,
    background_tasks: Vec<JoinHandle<()>>,
    contact_sync_in_flight: bool,
    contact_sync_retry_at: Option<OffsetDateTime>,
    contact_sync_attempts: u32,
    contact_sync_error: Option<String>,
    coordinator_journal_error: Option<String>,
}

impl GatewayInstance {
    async fn start(
        config: ValidatedGatewayConfig,
        secrets: RuntimeSecrets,
    ) -> Result<GatewayHandle, String> {
        let storage = GatewayStorage::initialize(config.source.storage_dir.clone())?;
        let pending_cleanups = storage.load_cleanup_journal()?;
        let mut coordinator_journal = storage.load_coordinator_journal()?;
        let certificates = DynamicCertificateStore::new();
        let http_only_domains = Arc::new(ArcSwap::from_pointee(BTreeSet::new()));
        certificates.update_routes(&config);
        let challenges = Http01ChallengeStore::new();
        let acme = AcmeContext::new(
            config.source.acme.clone(),
            storage.clone(),
            challenges.clone(),
        );
        let (acme_event_sender, acme_events) = mpsc::unbounded_channel();
        let route_table = build_route_table(&config, None);
        let routes = SharedRouteTable::new(route_table);
        let local_dns = SharedLocalDnsTable::new(LocalDnsTable::from_config(&config));

        let mut certificate_status = BTreeMap::new();
        for certificate in config.certificates.values() {
            let stored_schedule = coordinator_journal
                .certificates
                .get(&certificate.id)
                .filter(|stored| stored.policy_key == certificate_policy_key(certificate))
                .cloned();
            let mut status = CertificateStatus::pending(
                certificate.id.clone(),
                certificate.domains.clone(),
                certificate.authority,
                certificate.challenge.kind().to_string(),
            );
            match storage.load_certificate(&certificate.id, &certificate.domains) {
                Ok(Some(material)) => {
                    status.availability = certificate_availability(&material);
                    status.operation = if status.availability == CertificateAvailability::Valid
                        && certificate_policy_matches(certificate, &material)
                    {
                        CertificateOperation::Idle
                    } else {
                        CertificateOperation::Queued
                    };
                    status.not_before = Some(material.metadata.not_before_rfc3339.clone());
                    status.not_after = Some(material.metadata.not_after_rfc3339.clone());
                    status.active_authority = Some(material.metadata.authority);
                    status.active_challenge = Some(material.metadata.challenge.kind().to_string());
                    if certificate.automatic {
                        status.authority = material.metadata.authority;
                    }
                    if status.availability == CertificateAvailability::Valid {
                        let schedule = coordinator_journal
                            .certificates
                            .entry(certificate.id.clone())
                            .or_insert_with(|| empty_certificate_schedule(certificate));
                        schedule.preferred_authority = Some(material.metadata.authority);
                        schedule.ever_activated_https = true;
                        certificates.install(certificate.id.clone(), material);
                    }
                }
                Ok(None) => {
                    if certificate.automatic
                        && let Some(authority) = stored_schedule
                            .as_ref()
                            .and_then(|stored| stored.preferred_authority)
                    {
                        status.authority = authority;
                    }
                }
                Err(error) => {
                    status.operation = CertificateOperation::Suspended;
                    status.failure = Some(simple_failure(
                        FailureSource::Storage,
                        FailureKind::Permanent,
                        "certificate_load_failed",
                        error,
                    ));
                }
            }
            certificate_status.insert(certificate.id.clone(), status);
        }

        let server_conf = ServerConf {
            threads: 1,
            upstream_keepalive_pool_size: 128,
            max_retries: 1,
            ..ServerConf::default()
        };
        let server_conf = Arc::new(server_conf);
        let gateway_proxy = GatewayProxy::new(
            routes.clone(),
            certificates.clone(),
            challenges.clone(),
            http_only_domains.clone(),
        );
        let proxy = Arc::new(http_proxy(&server_conf, gateway_proxy));
        let (tls_acceptor, tls_callbacks) = build_tls_acceptor(certificates.clone())?;

        let http_listener = TcpListener::bind(config.http_addr).await.map_err(|error| {
            format!("failed to bind HTTP listener {}: {error}", config.http_addr)
        })?;
        let https_listener = match TcpListener::bind(config.https_addr).await {
            Ok(listener) => listener,
            Err(error) => {
                drop(http_listener);
                return Err(format!(
                    "failed to bind HTTPS listener {}: {error}",
                    config.https_addr
                ));
            }
        };
        let (dns_tcp_listener, dns_udp_socket, dns_addr) =
            match bind_local_dns(config.dns_addr).await {
                Ok(listeners) => listeners,
                Err(error) => {
                    drop(http_listener);
                    drop(https_listener);
                    return Err(error);
                }
            };
        let http_addr = http_listener
            .local_addr()
            .map_err(|error| format!("failed to inspect HTTP listener: {error}"))?;
        let https_addr = https_listener
            .local_addr()
            .map_err(|error| format!("failed to inspect HTTPS listener: {error}"))?;

        let (shutdown, shutdown_watch) = watch::channel(false);
        let http_task = tokio::spawn(run_http_listener(
            http_listener,
            proxy.clone(),
            shutdown_watch.clone(),
        ));
        let https_task = tokio::spawn(run_https_listener(
            https_listener,
            proxy.clone(),
            tls_acceptor,
            tls_callbacks,
            shutdown_watch.clone(),
        ));
        let mut dns_tasks = spawn_local_dns(
            dns_tcp_listener,
            dns_udp_socket,
            local_dns.clone(),
            certificates.clone(),
            shutdown_watch.clone(),
        );
        let route_tasks = spawn_route_resolvers(routes.snapshot(), shutdown_watch);

        let status = Arc::new(ArcSwap::from_pointee(GatewayStatusSnapshot::default()));
        let listener_status = ListenerStatus {
            http: Some(http_addr.to_string()),
            https: Some(https_addr.to_string()),
            dns: Some(dns_addr.to_string()),
        };
        let mut listener_tasks = vec![http_task, https_task];
        listener_tasks.append(&mut dns_tasks);
        let provider_cooldowns = coordinator_journal
            .provider_cooldowns
            .iter()
            .filter_map(|(authority, cooldown)| {
                parse_timestamp(&cooldown.until)
                    .filter(|until| *until > OffsetDateTime::now_utc())
                    .map(|until| (*authority, (until, cooldown.reason.clone())))
            })
            .collect();
        let mut instance = Self {
            config,
            secrets,
            storage,
            acme,
            acme_events,
            acme_event_sender,
            certificates: certificates.clone(),
            http_only_domains: http_only_domains.clone(),
            routes: routes.clone(),
            local_dns,
            proxy,
            shutdown,
            listener_tasks,
            route_tasks,
            status: status.clone(),
            certificate_status,
            listener_status,
            queued_certificates: BTreeSet::new(),
            in_flight_certificates: BTreeSet::new(),
            ari_in_flight: BTreeSet::new(),
            renewal_at: BTreeMap::new(),
            retry_attempts: BTreeMap::new(),
            provider_cooldowns,
            coordinator_journal,
            pending_cleanups,
            cleanup_in_flight: false,
            background_tasks: Vec::new(),
            contact_sync_in_flight: false,
            contact_sync_retry_at: Some(OffsetDateTime::now_utc()),
            contact_sync_attempts: 0,
            contact_sync_error: None,
            coordinator_journal_error: None,
        };
        instance.initialize_renewal_schedule();
        instance.enqueue_due_certificates();
        instance.drain_certificate_queue();
        instance.retry_pending_cleanups();
        instance.sync_contacts_if_due();
        instance.publish_status(GatewayState::Running, None);

        let (commands, receiver) = mpsc::channel(16);
        tokio::spawn(instance.run(receiver));
        Ok(GatewayHandle {
            commands,
            status,
            routes,
            certificates: certificates.clone(),
            http_only_domains: http_only_domains.clone(),
            #[cfg(test)]
            challenges,
        })
    }

    async fn run(mut self, mut commands: mpsc::Receiver<GatewayCommand>) {
        let mut scheduler = interval(ACME_SCHEDULER_INTERVAL);
        scheduler.set_missed_tick_behavior(MissedTickBehavior::Delay);
        scheduler.tick().await;

        loop {
            tokio::select! {
                command = commands.recv() => {
                    let Some(command) = command else { break };
                    match command {
                        GatewayCommand::Apply {
                            config,
                            secrets,
                            reply,
                        } => {
                            let result = self.apply(*config, secrets).await;
                            let _ = reply.send(result);
                        }
                        GatewayCommand::Renew {
                            certificate_id,
                            reply,
                        } => {
                            let result = self.request_renewal(certificate_id.as_deref());
                            let _ = reply.send(result);
                        }
                        GatewayCommand::Stop { reply } => {
                            self.publish_status(GatewayState::Stopping, None);
                            let _ = self.shutdown.send(true);
                            self.wait_for_background_tasks().await;
                            let result = self.stop_listeners().await;
                            self.publish_status(
                                if result.is_ok() {
                                    GatewayState::Stopped
                                } else {
                                    GatewayState::Failed
                                },
                                result.as_ref().err().cloned(),
                            );
                            let _ = reply.send(result);
                            break;
                        }
                    }
                }
                Some(event) = self.acme_events.recv() => {
                    self.handle_acme_event(event);
                }
                _ = scheduler.tick() => {
                    self.enqueue_due_certificates();
                    self.drain_certificate_queue();
                    self.retry_pending_cleanups();
                    self.sync_contacts_if_due();
                    self.background_tasks.retain(|task| !task.is_finished());
                }
            }
        }
        if !*self.shutdown.borrow() {
            let _ = self.shutdown.send(true);
            self.wait_for_background_tasks().await;
            let _ = self.stop_listeners().await;
        }
    }

    async fn apply(
        &mut self,
        config: ValidatedGatewayConfig,
        secrets: Option<RuntimeSecrets>,
    ) -> Result<(), String> {
        self.validate_immutable_config(&config)?;
        let changed_certificate_ids =
            changed_certificate_ids(&self.config.certificates, &config.certificates)
                .into_iter()
                .collect::<BTreeSet<_>>();
        match secrets.as_ref() {
            Some(secrets) => secrets.validate_references(&config)?,
            None => self.secrets.validate_references(&config)?,
        }

        let previous_route_table = self.routes.snapshot();
        let route_table = build_route_table(&config, Some(previous_route_table.as_ref()));
        self.acme.update_config(config.source.acme.clone()).await?;
        let contact_changed = self.config.source.acme != config.source.acme;
        let mut next_status = BTreeMap::new();
        for certificate in config.certificates.values() {
            let status = if !changed_certificate_ids.contains(&certificate.id)
                && let Some(status) = self.certificate_status.get(&certificate.id)
                && status.domains == certificate.domains
                && status.authority == certificate.authority
                && status.challenge == certificate.challenge.kind()
            {
                status.clone()
            } else {
                match self
                    .storage
                    .load_certificate(&certificate.id, &certificate.domains)
                {
                    Ok(Some(material)) => {
                        let availability = certificate_availability(&material);
                        if availability == CertificateAvailability::Valid {
                            self.certificates
                                .install(certificate.id.clone(), material.clone());
                        }
                        CertificateStatus {
                            id: certificate.id.clone(),
                            domains: certificate.domains.clone(),
                            authority: if certificate.automatic {
                                material.metadata.authority
                            } else {
                                certificate.authority
                            },
                            challenge: certificate.challenge.kind().to_string(),
                            active_authority: Some(material.metadata.authority),
                            active_challenge: Some(material.metadata.challenge.kind().to_string()),
                            availability,
                            operation: if availability == CertificateAvailability::Valid
                                && certificate_policy_matches(certificate, &material)
                            {
                                CertificateOperation::Idle
                            } else {
                                CertificateOperation::Queued
                            },
                            stage: None,
                            not_before: Some(material.metadata.not_before_rfc3339.clone()),
                            not_after: Some(material.metadata.not_after_rfc3339.clone()),
                            next_renewal_at: None,
                            next_attempt_at: None,
                            last_attempt_at: None,
                            failure: None,
                        }
                    }
                    Ok(None) => CertificateStatus::pending(
                        certificate.id.clone(),
                        certificate.domains.clone(),
                        certificate.authority,
                        certificate.challenge.kind().to_string(),
                    ),
                    Err(error) => {
                        let mut status = CertificateStatus::pending(
                            certificate.id.clone(),
                            certificate.domains.clone(),
                            certificate.authority,
                            certificate.challenge.kind().to_string(),
                        );
                        status.operation = CertificateOperation::Suspended;
                        status.failure = Some(simple_failure(
                            FailureSource::Storage,
                            FailureKind::Permanent,
                            "certificate_load_failed",
                            error,
                        ));
                        status
                    }
                }
            };
            next_status.insert(certificate.id.clone(), status);
        }

        if let Some(secrets) = secrets {
            self.secrets = secrets;
        }
        self.certificates.reconcile(&config);
        self.certificates.update_routes(&config);
        self.local_dns.replace(LocalDnsTable::from_config(&config));
        let mut next_route_tasks = BTreeMap::new();
        for (domain, task) in std::mem::take(&mut self.route_tasks) {
            let runtime_unchanged = previous_route_table
                .get(&domain)
                .zip(route_table.get(&domain))
                .is_some_and(|(previous, next)| Arc::ptr_eq(&previous, &next));
            if runtime_unchanged && !task.is_finished() {
                next_route_tasks.insert(domain, task);
            } else {
                task.abort();
                let _ = task.await;
            }
        }
        for (domain, route) in route_table.all_routes() {
            if !next_route_tasks.contains_key(&domain) {
                next_route_tasks.insert(
                    domain,
                    spawn_route_resolver(route, self.shutdown.subscribe()),
                );
            }
        }
        self.routes.replace(route_table.clone());
        self.route_tasks = next_route_tasks;
        self.certificate_status = next_status;
        self.config = config;
        if contact_changed {
            self.contact_sync_attempts = 0;
            self.contact_sync_retry_at = Some(OffsetDateTime::now_utc());
            self.contact_sync_error = None;
        }
        for certificate_id in changed_certificate_ids {
            self.renewal_at.remove(&certificate_id);
            self.retry_attempts.remove(&certificate_id);
            self.queued_certificates.remove(&certificate_id);
        }
        self.renewal_at
            .retain(|certificate_id, _| self.config.certificates.contains_key(certificate_id));
        self.retry_attempts
            .retain(|certificate_id, _| self.config.certificates.contains_key(certificate_id));
        self.queued_certificates
            .retain(|certificate_id| self.config.certificates.contains_key(certificate_id));
        self.coordinator_journal
            .certificates
            .retain(|certificate_id, stored| {
                self.config
                    .certificates
                    .get(certificate_id)
                    .is_some_and(|certificate| {
                        stored.policy_key == certificate_policy_key(certificate)
                    })
            });
        let _ = self.persist_coordinator_journal();
        self.initialize_renewal_schedule();
        self.enqueue_due_certificates();
        self.drain_certificate_queue();
        self.retry_pending_cleanups();
        self.sync_contacts_if_due();
        self.publish_status(GatewayState::Running, None);
        Ok(())
    }

    fn initialize_renewal_schedule(&mut self) {
        let now = OffsetDateTime::now_utc();
        let certificate_ids = self.config.certificates.keys().cloned().collect::<Vec<_>>();
        for certificate_id in certificate_ids {
            if let Some(scheduled_at) = self.renewal_at.get(&certificate_id).copied() {
                if self
                    .certificate_status
                    .get(&certificate_id)
                    .is_some_and(|status| {
                        matches!(
                            status.operation,
                            CertificateOperation::Queued | CertificateOperation::WaitingRetry
                        )
                    })
                {
                    self.update_next_attempt_status(&certificate_id, scheduled_at);
                } else {
                    self.update_next_renewal_status(&certificate_id, scheduled_at);
                }
                continue;
            }

            let certificate = &self.config.certificates[&certificate_id];
            let policy_key = certificate_policy_key(certificate);
            if let Some(stored) = self
                .coordinator_journal
                .certificates
                .get(&certificate_id)
                .filter(|stored| stored.policy_key == policy_key)
                .cloned()
            {
                let has_valid_certificate = self
                    .certificates
                    .get(&certificate_id)
                    .is_some_and(|material| material.metadata.not_after > now);
                if stored.in_flight {
                    let attempt_count = stored.attempt_count.saturating_add(1);
                    self.retry_attempts
                        .insert(certificate_id.clone(), attempt_count);
                    let retry_at = now + time::Duration::minutes(1);
                    let mut failure = simple_failure(
                        FailureSource::Runtime,
                        FailureKind::Interrupted,
                        "runtime_restarted_during_attempt",
                        "The Gateway restarted during a certificate attempt".to_string(),
                    );
                    failure.retry_at = Some(format_timestamp(retry_at));
                    self.set_retry_time(&certificate_id, retry_at);
                    if let Some(status) = self.certificate_status.get_mut(&certificate_id) {
                        CertificateStateMachine::wait_for_retry(
                            status,
                            has_valid_certificate,
                            failure.clone(),
                            retry_at,
                        );
                    }
                    self.coordinator_journal.certificates.insert(
                        certificate_id.clone(),
                        CertificateScheduleJournal {
                            policy_key,
                            preferred_authority: stored.preferred_authority,
                            ever_activated_https: stored.ever_activated_https,
                            attempt_count,
                            next_renewal_at: None,
                            next_attempt_at: Some(format_timestamp(retry_at)),
                            in_flight: false,
                            failure: Some(failure),
                        },
                    );
                    continue;
                }

                self.retry_attempts
                    .insert(certificate_id.clone(), stored.attempt_count);
                if let Some(failure) = stored.failure {
                    if matches!(
                        failure.kind,
                        FailureKind::UserActionRequired | FailureKind::Permanent
                    ) {
                        self.renewal_at.remove(&certificate_id);
                        if let Some(status) = self.certificate_status.get_mut(&certificate_id) {
                            CertificateStateMachine::suspend(
                                status,
                                has_valid_certificate,
                                failure,
                            );
                        }
                        continue;
                    }

                    let retry_at = stored
                        .next_attempt_at
                        .as_deref()
                        .and_then(parse_timestamp)
                        .or_else(|| failure.retry_at.as_deref().and_then(parse_timestamp))
                        .unwrap_or(now)
                        .max(now);
                    self.set_retry_time(&certificate_id, retry_at);
                    if let Some(status) = self.certificate_status.get_mut(&certificate_id) {
                        CertificateStateMachine::wait_for_retry(
                            status,
                            has_valid_certificate,
                            failure,
                            retry_at,
                        );
                    }
                    continue;
                }
                if let Some(next_attempt) =
                    stored.next_attempt_at.as_deref().and_then(parse_timestamp)
                {
                    self.set_retry_time(&certificate_id, next_attempt.max(now));
                    if let Some(status) = self.certificate_status.get_mut(&certificate_id) {
                        status.operation = CertificateOperation::Queued;
                    }
                    continue;
                }
                if let Some(next_renewal) =
                    stored.next_renewal_at.as_deref().and_then(parse_timestamp)
                {
                    self.set_renewal_time(&certificate_id, next_renewal.max(now));
                    continue;
                }
            }

            match self.certificates.get(&certificate_id) {
                Some(material) => {
                    let policy_matches = certificate_policy_matches(certificate, &material);
                    if policy_matches {
                        let renewal_at = initial_renewal_time(certificate, &material, now);
                        self.set_renewal_time(&certificate_id, renewal_at);
                        self.request_ari(&certificate_id, material);
                    } else {
                        self.set_retry_time(&certificate_id, now);
                    }
                }
                None => self.set_retry_time(&certificate_id, now),
            }
        }
        let _ = self.persist_coordinator_journal();
    }

    fn enqueue_due_certificates(&mut self) {
        let now = OffsetDateTime::now_utc();
        self.provider_cooldowns.retain(|_, (until, _)| *until > now);
        let due =
            self.renewal_at
                .iter()
                .filter(|(certificate_id, renewal_at)| {
                    **renewal_at <= now
                        && self.config.certificates.contains_key(*certificate_id)
                        && !self.in_flight_certificates.contains(*certificate_id)
                        && self.config.certificates.get(*certificate_id).is_some_and(
                            |certificate| {
                                let authority = self
                                    .coordinator_journal
                                    .certificates
                                    .get(*certificate_id)
                                    .and_then(|stored| stored.preferred_authority)
                                    .unwrap_or(certificate.authority);
                                self.provider_cooldowns
                                    .get(&authority)
                                    .is_none_or(|(until, _)| *until <= now)
                            },
                        )
                })
                .map(|(certificate_id, _)| certificate_id.clone())
                .collect::<Vec<_>>();
        self.queued_certificates.extend(due);
    }

    fn drain_certificate_queue(&mut self) {
        if *self.shutdown.borrow() {
            return;
        }

        while self.in_flight_certificates.len() < MAX_CONCURRENT_ACME_ORDERS {
            let Some(certificate_id) = self.queued_certificates.pop_first() else {
                break;
            };
            let Some(certificate) = self.config.certificates.get(&certificate_id).cloned() else {
                continue;
            };
            if !certificate.renewal_enabled {
                continue;
            }
            let desired_policy_key = certificate_policy_key(&certificate);
            let existing_schedule = self
                .coordinator_journal
                .certificates
                .get(&certificate_id)
                .cloned();
            let mut certificate = certificate;
            if certificate.automatic {
                let preferred_authority = existing_schedule
                    .as_ref()
                    .and_then(|stored| stored.preferred_authority)
                    .or_else(|| {
                        self.certificate_status
                            .get(&certificate_id)
                            .map(|status| status.authority)
                    });
                if preferred_authority == Some(config::CertificateAuthorityKind::Zerossl) {
                    certificate.authority = config::CertificateAuthorityKind::Zerossl;
                }
            }
            let dns_credential =
                certificate
                    .challenge
                    .dns01()
                    .and_then(|(provider, credential_id)| {
                        self.secrets.dns_credential(provider, credential_id)
                    });

            let current = self.certificates.get(&certificate_id);
            let current_leaf_der = current
                .as_ref()
                .map(|material| material.metadata.leaf_der.clone());
            self.coordinator_journal.certificates.insert(
                certificate_id.clone(),
                CertificateScheduleJournal {
                    policy_key: desired_policy_key,
                    preferred_authority: Some(certificate.authority),
                    ever_activated_https: existing_schedule
                        .as_ref()
                        .is_some_and(|stored| stored.ever_activated_https),
                    attempt_count: self
                        .retry_attempts
                        .get(&certificate_id)
                        .copied()
                        .unwrap_or(0),
                    next_renewal_at: None,
                    next_attempt_at: None,
                    in_flight: true,
                    failure: None,
                },
            );
            if let Err(error) = self.persist_coordinator_journal() {
                if let Some(status) = self.certificate_status.get_mut(&certificate_id) {
                    let failure = simple_failure(
                        FailureSource::Storage,
                        FailureKind::Permanent,
                        "coordinator_journal_write_failed",
                        error,
                    );
                    let has_valid_certificate = current.as_ref().is_some_and(|material| {
                        material.metadata.not_after > OffsetDateTime::now_utc()
                    });
                    CertificateStateMachine::suspend(status, has_valid_certificate, failure);
                }
                self.renewal_at.remove(&certificate_id);
                self.coordinator_journal
                    .certificates
                    .remove(&certificate_id);
                continue;
            }
            self.renewal_at.remove(&certificate_id);
            if let Some(status) = self.certificate_status.get_mut(&certificate_id) {
                CertificateStateMachine::begin_attempt(
                    status,
                    current.is_some(),
                    current
                        .as_ref()
                        .is_some_and(|material| certificate_policy_matches(&certificate, material)),
                    OffsetDateTime::now_utc(),
                );
            }
            self.in_flight_certificates.insert(certificate_id.clone());

            let acme = self.acme.clone();
            let events = self.acme_event_sender.clone();
            let progress_events = events.clone();
            let progress_certificate = certificate.clone();
            let cancellation = self.shutdown.subscribe();
            self.background_tasks.push(tokio::spawn(async move {
                let output = acme
                    .issue(
                        certificate,
                        dns_credential,
                        current_leaf_der,
                        cancellation,
                        move |stage| {
                            let _ = progress_events.send(AcmeEvent::AttemptProgress {
                                attempted_certificate: progress_certificate.clone(),
                                stage,
                            });
                        },
                    )
                    .await;
                let _ = events.send(AcmeEvent::JobFinished(output));
            }));
        }
    }

    fn retry_pending_cleanups(&mut self) {
        if self.cleanup_in_flight || self.pending_cleanups.is_empty() || *self.shutdown.borrow() {
            return;
        }

        let now = OffsetDateTime::now_utc();
        let attempted = self
            .pending_cleanups
            .iter()
            .filter(|cleanup| {
                cleanup
                    .next_attempt_at
                    .as_deref()
                    .and_then(parse_timestamp)
                    .is_none_or(|next_attempt| next_attempt <= now)
            })
            .cloned()
            .collect::<Vec<_>>();
        if attempted.is_empty() {
            return;
        }
        let credentials = attempted
            .iter()
            .filter_map(|cleanup| {
                self.secrets
                    .dns_credential_for_cleanup(cleanup)
                    .map(|credential| (cleanup.credential_id.clone(), credential))
            })
            .collect::<BTreeMap<_, _>>();
        let acme = self.acme.clone();
        let storage = self.storage.clone();
        let events = self.acme_event_sender.clone();
        let attempted_for_event = attempted.clone();
        self.cleanup_in_flight = true;
        self.background_tasks.push(tokio::spawn(async move {
            let mut remaining = Vec::new();
            let mut last_error = None;
            for mut cleanup in attempted {
                let result = match credentials.get(&cleanup.credential_id) {
                    Some(credential) => acme.retry_cleanup(&cleanup, credential).await,
                    None => Err(format!(
                        "DNS credential {} is unavailable for cleanup {}",
                        cleanup.credential_id, cleanup.record_name
                    )),
                };
                if let Err(error) = result {
                    cleanup.attempt_count = cleanup.attempt_count.saturating_add(1);
                    let retry_at = OffsetDateTime::now_utc()
                        + time::Duration::try_from(retry_delay(cleanup.attempt_count))
                            .unwrap_or(time::Duration::hours(6));
                    cleanup.next_attempt_at = Some(format_timestamp(retry_at));
                    cleanup.last_error = Some(error.clone());
                    last_error = Some(error);
                    remaining.push(cleanup);
                }
            }
            if let Err(error) = storage.complete_cleanup_attempt(&attempted_for_event, &remaining) {
                last_error = Some(match last_error {
                    Some(existing) => format!("{existing}; {error}"),
                    None => error,
                });
            }
            let _ = events.send(AcmeEvent::CleanupRetried {
                attempted: attempted_for_event,
                remaining,
                last_error,
            });
        }));
    }

    fn sync_contacts_if_due(&mut self) {
        if self.contact_sync_in_flight || *self.shutdown.borrow() {
            return;
        }
        let now = OffsetDateTime::now_utc();
        if self
            .contact_sync_retry_at
            .is_some_and(|retry_at| retry_at > now)
        {
            return;
        }
        if self.contact_sync_retry_at.is_none() {
            return;
        }
        self.contact_sync_in_flight = true;
        let acme = self.acme.clone();
        let events = self.acme_event_sender.clone();
        self.background_tasks.push(tokio::spawn(async move {
            let _ = events.send(AcmeEvent::ContactsSynced(acme.sync_contacts().await));
        }));
    }

    fn handle_acme_event(&mut self, event: AcmeEvent) {
        let mut status_error = None;
        match event {
            AcmeEvent::AttemptProgress {
                attempted_certificate,
                stage,
            } => {
                if self
                    .config
                    .certificates
                    .get(&attempted_certificate.id)
                    .is_some_and(|certificate| *certificate == attempted_certificate)
                    && let Some(status) = self.certificate_status.get_mut(&attempted_certificate.id)
                    && matches!(
                        status.operation,
                        CertificateOperation::Issuing
                            | CertificateOperation::Renewing
                            | CertificateOperation::Replacing
                    )
                {
                    status.stage = Some(stage);
                }
            }
            AcmeEvent::JobFinished(output) => {
                self.in_flight_certificates.remove(&output.certificate_id);
                let output_matches_current = self
                    .config
                    .certificates
                    .get(&output.certificate_id)
                    .is_some_and(|certificate| output.matches(certificate));
                status_error = output.cleanup_journal_error;
                if !output.cleanup_failures.is_empty() {
                    self.merge_pending_cleanups(output.cleanup_failures);
                    if let Err(error) = self.persist_cleanup_journal() {
                        status_error = Some(match status_error {
                            Some(existing) => format!("{existing}; {error}"),
                            None => error,
                        });
                    }
                }

                let Some(certificate) = self
                    .config
                    .certificates
                    .get(&output.certificate_id)
                    .cloned()
                else {
                    self.drain_certificate_queue();
                    self.publish_status(self.operational_state(), status_error);
                    return;
                };

                if !output_matches_current {
                    self.coordinator_journal
                        .certificates
                        .remove(&output.certificate_id);
                    let _ = self.persist_coordinator_journal();
                    let retry_at = OffsetDateTime::now_utc();
                    self.set_retry_time(&output.certificate_id, retry_at);
                    self.queued_certificates
                        .insert(output.certificate_id.clone());
                    if let Some(status) = self.certificate_status.get_mut(&output.certificate_id) {
                        CertificateStateMachine::queue_superseded_result(
                            status,
                            simple_failure(
                                FailureSource::Configuration,
                                FailureKind::Interrupted,
                                "stale_attempt_discarded",
                                "Discarded a certificate result for a superseded configuration"
                                    .to_string(),
                            ),
                        );
                        status.next_attempt_at = Some(format_timestamp(retry_at));
                    }
                    self.enqueue_due_certificates();
                    self.drain_certificate_queue();
                    self.publish_status(self.operational_state(), status_error);
                    return;
                }

                match output.result {
                    Ok(issued) if issued.material.metadata.domains != certificate.domains => {
                        self.record_issuance_failure(
                            &output.certificate_id,
                            simple_failure(
                                FailureSource::CertificateValidation,
                                FailureKind::Permanent,
                                "issued_certificate_domains_mismatch",
                                "The issued certificate does not contain the configured domains"
                                    .to_string(),
                            ),
                        );
                    }
                    Ok(issued)
                        if issued.material.metadata.not_after <= OffsetDateTime::now_utc() =>
                    {
                        self.record_issuance_failure(
                            &output.certificate_id,
                            simple_failure(
                                FailureSource::CertificateValidation,
                                FailureKind::Permanent,
                                "issued_certificate_expired",
                                "The issued certificate is already expired".to_string(),
                            ),
                        );
                    }
                    Ok(issued) => {
                        if let Some(status) =
                            self.certificate_status.get_mut(&output.certificate_id)
                        {
                            status.stage = Some(status::CertificateStage::Installing);
                        }
                        self.publish_status(self.operational_state(), status_error.clone());
                        match issued.commit(&self.storage, &output.attempted_certificate) {
                            Ok(material) => {
                                self.certificates
                                    .install(output.certificate_id.clone(), material.clone());
                                self.retry_attempts.remove(&output.certificate_id);
                                let schedule = self
                                    .coordinator_journal
                                    .certificates
                                    .entry(output.certificate_id.clone())
                                    .or_insert_with(|| empty_certificate_schedule(&certificate));
                                schedule.preferred_authority = Some(material.metadata.authority);
                                schedule.ever_activated_https = true;
                                if let Some(status) =
                                    self.certificate_status.get_mut(&output.certificate_id)
                                {
                                    CertificateStateMachine::install(status, &material);
                                    if certificate.automatic {
                                        status.authority = material.metadata.authority;
                                    }
                                }
                                let renewal_at = fallback_renewal_time(
                                    material.metadata.not_before,
                                    material.metadata.not_after,
                                );
                                self.set_renewal_time(&output.certificate_id, renewal_at);
                                self.request_ari(&output.certificate_id, material);
                            }
                            Err(error) => {
                                self.record_issuance_failure(
                                    &output.certificate_id,
                                    simple_failure(
                                        FailureSource::Storage,
                                        FailureKind::Permanent,
                                        "certificate_install_failed",
                                        error,
                                    ),
                                );
                            }
                        }
                    }
                    Err(failure) => {
                        if certificate.automatic
                            && output.attempted_certificate.authority
                                == config::CertificateAuthorityKind::Letsencrypt
                            && automatic_fallback_eligible(&failure)
                        {
                            if let Some(status) =
                                self.certificate_status.get_mut(&output.certificate_id)
                            {
                                status.authority = config::CertificateAuthorityKind::Zerossl;
                                status.challenge = certificate.challenge.kind().to_string();
                                status.failure = Some(failure.clone());
                                status.operation = CertificateOperation::Queued;
                                status.next_attempt_at =
                                    Some(format_timestamp(OffsetDateTime::now_utc()));
                            }
                            self.retry_attempts.remove(&output.certificate_id);
                            let schedule = self
                                .coordinator_journal
                                .certificates
                                .entry(output.certificate_id.clone())
                                .or_insert_with(|| empty_certificate_schedule(&certificate));
                            schedule.preferred_authority =
                                Some(config::CertificateAuthorityKind::Zerossl);
                            schedule.in_flight = false;
                            schedule.failure = None;
                            let retry_at = OffsetDateTime::now_utc();
                            schedule.next_attempt_at = Some(format_timestamp(retry_at));
                            self.set_retry_time(&output.certificate_id, retry_at);
                            self.queued_certificates
                                .insert(output.certificate_id.clone());
                        } else {
                            self.record_issuance_failure(&output.certificate_id, failure);
                        }
                    }
                }
                self.contact_sync_retry_at = Some(OffsetDateTime::now_utc());
            }
            AcmeEvent::ContactsSynced(result) => {
                self.contact_sync_in_flight = false;
                match result {
                    Ok(()) => {
                        self.contact_sync_attempts = 0;
                        self.contact_sync_retry_at = None;
                        self.contact_sync_error = None;
                    }
                    Err(error) => {
                        self.contact_sync_attempts = self.contact_sync_attempts.saturating_add(1);
                        self.contact_sync_retry_at = Some(
                            OffsetDateTime::now_utc()
                                + time::Duration::try_from(retry_delay(self.contact_sync_attempts))
                                    .unwrap_or(time::Duration::hours(6)),
                        );
                        self.contact_sync_error = Some(error);
                    }
                }
            }
            AcmeEvent::RenewalSuggested {
                certificate_id,
                leaf_der,
                result,
            } => {
                self.ari_in_flight.remove(&certificate_id);
                let current = self.certificates.get(&certificate_id);
                if let Some(material) = current {
                    if material.metadata.leaf_der != leaf_der {
                        self.request_ari(&certificate_id, material);
                    } else if let Ok(Some(renewal_at)) = result {
                        let latest = material.metadata.not_after - time::Duration::seconds(1);
                        self.set_renewal_time(&certificate_id, renewal_at.min(latest));
                    }
                }
            }
            AcmeEvent::CleanupRetried {
                attempted,
                remaining,
                last_error,
            } => {
                self.cleanup_in_flight = false;
                self.pending_cleanups
                    .retain(|cleanup| !attempted.contains(cleanup));
                self.merge_pending_cleanups(remaining);
                status_error = last_error;
                if let Err(error) = self.persist_cleanup_journal() {
                    status_error = Some(match status_error {
                        Some(existing) => format!("{existing}; {error}"),
                        None => error,
                    });
                }
            }
        }

        self.enqueue_due_certificates();
        self.drain_certificate_queue();
        self.publish_status(self.operational_state(), status_error);
    }

    async fn wait_for_background_tasks(&mut self) {
        let deadline = Instant::now() + BACKGROUND_SHUTDOWN_TIMEOUT;
        loop {
            self.background_tasks.retain(|task| !task.is_finished());
            if self.in_flight_certificates.is_empty() && !self.cleanup_in_flight {
                break;
            }
            let now = Instant::now();
            if now >= deadline {
                break;
            }
            match timeout(deadline - now, self.acme_events.recv()).await {
                Ok(Some(event)) => self.handle_acme_event(event),
                Ok(None) | Err(_) => break,
            }
        }
        self.background_tasks.retain(|task| !task.is_finished());
    }

    fn request_ari(&mut self, certificate_id: &str, material: Arc<tls::CertifiedMaterial>) {
        if *self.shutdown.borrow() || !self.ari_in_flight.insert(certificate_id.to_string()) {
            return;
        }
        let certificate_id = certificate_id.to_string();
        let leaf_der = material.metadata.leaf_der.clone();
        let acme = self.acme.clone();
        let events = self.acme_event_sender.clone();
        self.background_tasks.push(tokio::spawn(async move {
            let result = acme
                .suggested_renewal_time(&material)
                .await
                .map(|suggested| suggested.map(|(renewal_at, _)| renewal_at));
            let _ = events.send(AcmeEvent::RenewalSuggested {
                certificate_id,
                leaf_der,
                result,
            });
        }));
    }

    fn record_issuance_failure(&mut self, certificate_id: &str, mut failure: CertificateFailure) {
        let now = OffsetDateTime::now_utc();
        let retry_at = match failure.kind {
            FailureKind::Transient | FailureKind::Interrupted => {
                let attempt = self
                    .retry_attempts
                    .entry(certificate_id.to_string())
                    .and_modify(|attempt| *attempt = attempt.saturating_add(1))
                    .or_insert(1);
                Some(
                    now + time::Duration::try_from(retry_delay(*attempt))
                        .unwrap_or(time::Duration::hours(6)),
                )
            }
            FailureKind::RateLimited => {
                let retry_at = failure
                    .retry_at
                    .as_deref()
                    .and_then(parse_timestamp)
                    .filter(|retry_at| *retry_at > now)
                    .unwrap_or(now + time::Duration::hours(1));
                if is_authority_cooldown_failure(&failure)
                    && let Some(authority) = failure.authority
                {
                    self.provider_cooldowns
                        .insert(authority, (retry_at, failure.clone()));
                }
                Some(retry_at)
            }
            FailureKind::UserActionRequired | FailureKind::Permanent => None,
        };
        if let Some(retry_at) = retry_at {
            self.set_retry_time(certificate_id, retry_at);
            failure.retry_at = Some(format_timestamp(retry_at));
        } else {
            self.renewal_at.remove(certificate_id);
        }
        if let Some(status) = self.certificate_status.get_mut(certificate_id) {
            let has_certificate = self
                .certificates
                .get(certificate_id)
                .is_some_and(|material| material.metadata.not_after > now);
            if !has_certificate {
                self.certificates.remove(certificate_id);
            }
            if let Some(retry_at) = retry_at {
                CertificateStateMachine::wait_for_retry(status, has_certificate, failure, retry_at);
            } else {
                CertificateStateMachine::suspend(status, has_certificate, failure);
            }
            if !has_certificate {
                self.certificates.remove(certificate_id);
            }
        }
        if let Some(certificate) = self.config.certificates.get(certificate_id) {
            let existing_schedule = self
                .coordinator_journal
                .certificates
                .get(certificate_id)
                .cloned();
            self.coordinator_journal.certificates.insert(
                certificate_id.to_string(),
                CertificateScheduleJournal {
                    policy_key: certificate_policy_key(certificate),
                    preferred_authority: existing_schedule
                        .as_ref()
                        .and_then(|stored| stored.preferred_authority)
                        .or(Some(certificate.authority)),
                    ever_activated_https: existing_schedule
                        .as_ref()
                        .is_some_and(|stored| stored.ever_activated_https),
                    attempt_count: self
                        .retry_attempts
                        .get(certificate_id)
                        .copied()
                        .unwrap_or(0),
                    next_renewal_at: None,
                    next_attempt_at: retry_at.map(format_timestamp),
                    in_flight: false,
                    failure: self
                        .certificate_status
                        .get(certificate_id)
                        .and_then(|status| status.failure.clone()),
                },
            );
            let _ = self.persist_coordinator_journal();
        }
    }

    fn set_renewal_time(&mut self, certificate_id: &str, renewal_at: OffsetDateTime) {
        self.renewal_at
            .insert(certificate_id.to_string(), renewal_at);
        self.update_next_renewal_status(certificate_id, renewal_at);
        if let Some(certificate) = self.config.certificates.get(certificate_id) {
            let entry = self
                .coordinator_journal
                .certificates
                .entry(certificate_id.to_string())
                .or_insert_with(|| CertificateScheduleJournal {
                    policy_key: certificate_policy_key(certificate),
                    preferred_authority: Some(certificate.authority),
                    ever_activated_https: self.certificates.get(certificate_id).is_some(),
                    attempt_count: 0,
                    next_renewal_at: None,
                    next_attempt_at: None,
                    in_flight: false,
                    failure: None,
                });
            entry.policy_key = certificate_policy_key(certificate);
            entry.attempt_count = 0;
            entry.next_renewal_at = Some(format_timestamp(renewal_at));
            entry.next_attempt_at = None;
            entry.in_flight = false;
            entry.failure = None;
            let _ = self.persist_coordinator_journal();
        }
    }

    fn set_retry_time(&mut self, certificate_id: &str, retry_at: OffsetDateTime) {
        self.renewal_at.insert(certificate_id.to_string(), retry_at);
        self.update_next_attempt_status(certificate_id, retry_at);
    }

    fn update_next_renewal_status(&mut self, certificate_id: &str, renewal_at: OffsetDateTime) {
        if let Some(status) = self.certificate_status.get_mut(certificate_id) {
            status.next_renewal_at = Some(format_timestamp(renewal_at));
            status.next_attempt_at = None;
        }
    }

    fn update_next_attempt_status(&mut self, certificate_id: &str, retry_at: OffsetDateTime) {
        if let Some(status) = self.certificate_status.get_mut(certificate_id) {
            status.next_renewal_at = None;
            status.next_attempt_at = Some(format_timestamp(retry_at));
        }
    }

    fn merge_pending_cleanups(&mut self, cleanups: Vec<PendingDnsCleanup>) {
        for cleanup in cleanups {
            if !self.pending_cleanups.iter().any(|existing| {
                existing.provider == cleanup.provider
                    && existing.credential_id == cleanup.credential_id
                    && existing.zone_id == cleanup.zone_id
                    && existing.record_id == cleanup.record_id
            }) {
                self.pending_cleanups.push(cleanup);
            }
        }
    }

    fn persist_cleanup_journal(&self) -> Result<(), String> {
        self.storage.store_cleanup_journal(&self.pending_cleanups)
    }

    fn persist_coordinator_journal(&mut self) -> Result<(), String> {
        self.coordinator_journal.provider_cooldowns = self
            .provider_cooldowns
            .iter()
            .map(|(authority, (until, reason))| {
                (
                    *authority,
                    ProviderCooldownJournal {
                        until: format_timestamp(*until),
                        reason: reason.clone(),
                    },
                )
            })
            .collect();
        match self
            .storage
            .store_coordinator_journal(&self.coordinator_journal)
        {
            Ok(()) => {
                self.coordinator_journal_error = None;
                Ok(())
            }
            Err(error) => {
                self.coordinator_journal_error = Some(error.clone());
                Err(error)
            }
        }
    }

    fn operational_state(&self) -> GatewayState {
        if *self.shutdown.borrow() {
            GatewayState::Stopping
        } else {
            GatewayState::Running
        }
    }

    fn validate_immutable_config(&self, config: &ValidatedGatewayConfig) -> Result<(), String> {
        if self.config.source.storage_dir != config.source.storage_dir {
            return Err("storage_dir changes require gateway stop/start".to_string());
        }
        if self.config.source.listeners != config.source.listeners {
            return Err("listener changes require gateway stop/start".to_string());
        }
        Ok(())
    }

    fn request_renewal(&mut self, certificate_id: Option<&str>) -> Result<(), String> {
        if let Some(certificate_id) = certificate_id
            && !self.config.certificates.contains_key(certificate_id)
        {
            return Err(format!("unknown gateway certificate {certificate_id}"));
        }
        match certificate_id {
            Some(certificate_id) => {
                if let Some(until) = self.active_rate_limit_until(certificate_id) {
                    return Err(format!(
                        "certificate provider is rate limited until {}",
                        format_timestamp(until)
                    ));
                }
                if let Some(certificate) = self.config.certificates.get(certificate_id)
                    && let Some((until, _)) = self.provider_cooldowns.get(&certificate.authority)
                    && *until > OffsetDateTime::now_utc()
                {
                    return Err(format!(
                        "{} is rate limited until {}",
                        certificate.authority.display_name(),
                        format_timestamp(*until)
                    ));
                }
                self.retry_attempts.remove(certificate_id);
                self.renewal_at.remove(certificate_id);
                self.coordinator_journal.certificates.remove(certificate_id);
                if !self.in_flight_certificates.contains(certificate_id) {
                    self.queued_certificates.insert(certificate_id.to_string());
                }
            }
            None => {
                for (certificate_id, certificate) in &self.config.certificates {
                    if self.active_rate_limit_until(certificate_id).is_some() {
                        continue;
                    }
                    if self
                        .provider_cooldowns
                        .get(&certificate.authority)
                        .is_some_and(|(until, _)| *until > OffsetDateTime::now_utc())
                    {
                        continue;
                    }
                    self.retry_attempts.remove(certificate_id);
                    self.renewal_at.remove(certificate_id);
                    self.coordinator_journal.certificates.remove(certificate_id);
                    if !self.in_flight_certificates.contains(certificate_id) {
                        self.queued_certificates.insert(certificate_id.clone());
                    }
                }
            }
        }
        self.drain_certificate_queue();
        let _ = self.persist_coordinator_journal();
        self.publish_status(GatewayState::Running, None);
        Ok(())
    }

    fn active_rate_limit_until(&self, certificate_id: &str) -> Option<OffsetDateTime> {
        let now = OffsetDateTime::now_utc();
        self.certificate_status
            .get(certificate_id)
            .and_then(|status| status.failure.as_ref())
            .filter(|failure| failure.kind == FailureKind::RateLimited)
            .and_then(|failure| failure.retry_at.as_deref())
            .and_then(parse_timestamp)
            .filter(|until| *until > now)
    }

    async fn stop_listeners(&mut self) -> Result<(), String> {
        let _ = self.shutdown.send(true);
        self.proxy.cleanup().await;
        for (_, task) in std::mem::take(&mut self.route_tasks) {
            task.abort();
            let _ = task.await;
        }
        let tasks = std::mem::take(&mut self.listener_tasks);
        timeout(
            CONNECTION_SHUTDOWN_TIMEOUT + Duration::from_secs(1),
            async {
                for task in tasks {
                    task.await
                        .map_err(|error| format!("gateway listener task failed: {error}"))?;
                }
                Ok::<(), String>(())
            },
        )
        .await
        .map_err(|_| "gateway listeners did not stop before the timeout".to_string())?
    }

    fn publish_status(&mut self, state: GatewayState, last_error: Option<String>) {
        let http_only_domains = self
            .config
            .routes
            .values()
            .filter_map(|route| {
                let certificate = self.config.certificates.get(&route.certificate_id)?;
                let status = self.certificate_status.get(&route.certificate_id)?;
                let fallback_available = route
                    .fallback_certificate_id
                    .as_deref()
                    .is_some_and(|id| self.certificates.get(id).is_some());
                let ever_activated_https = self
                    .coordinator_journal
                    .certificates
                    .get(&certificate.id)
                    .is_some_and(|stored| stored.ever_activated_https);
                automatic_http_only_eligible(
                    certificate,
                    status,
                    self.certificates.get(&route.certificate_id).is_some(),
                    fallback_available,
                    ever_activated_https,
                )
                .then(|| route.domain.clone())
            })
            .collect();
        self.http_only_domains.store(Arc::new(http_only_domains));

        let mut certificates = self
            .certificate_status
            .values()
            .cloned()
            .collect::<Vec<_>>();
        certificates.sort_by(|left, right| left.id.cmp(&right.id));
        let occurred_at = format_timestamp(OffsetDateTime::now_utc());
        let mut runtime_issues = Vec::new();
        if let Some(message) = last_error {
            runtime_issues.push(RuntimeIssue {
                code: "gateway_runtime_issue".to_string(),
                message,
                occurred_at: occurred_at.clone(),
            });
        }
        if let Some(message) = self.certificates.callback_error() {
            runtime_issues.push(RuntimeIssue {
                code: "tls_callback_failed".to_string(),
                message,
                occurred_at: occurred_at.clone(),
            });
        }
        if let Some(message) = self.contact_sync_error.clone() {
            runtime_issues.push(RuntimeIssue {
                code: "acme_contact_sync_failed".to_string(),
                message,
                occurred_at: occurred_at.clone(),
            });
        }
        if let Some(message) = self.coordinator_journal_error.clone() {
            runtime_issues.push(RuntimeIssue {
                code: "coordinator_journal_write_failed".to_string(),
                message,
                occurred_at,
            });
        }
        self.status.store(Arc::new(GatewayStatusSnapshot {
            schema_version: GATEWAY_SCHEMA_VERSION,
            state,
            applied_deployment: Some(self.config.source.deployment.clone()),
            listeners: self.listener_status.clone(),
            routes: self.routes.statuses(),
            certificates,
            pending_dns_cleanups: self.pending_cleanups.len(),
            provider_cooldowns: self
                .provider_cooldowns
                .iter()
                .map(
                    |(authority, (until, reason))| status::ProviderCooldownStatus {
                        authority: *authority,
                        until: format_timestamp(*until),
                        reason: reason.clone(),
                    },
                )
                .collect(),
            runtime_issues,
        }));
    }
}

fn changed_certificate_ids(
    current: &BTreeMap<String, ValidatedCertificate>,
    next: &BTreeMap<String, ValidatedCertificate>,
) -> Vec<String> {
    next.iter()
        .filter(|(certificate_id, certificate)| {
            current
                .get(*certificate_id)
                .is_some_and(|current| current != *certificate)
        })
        .map(|(certificate_id, _)| certificate_id.clone())
        .collect()
}

fn is_authority_cooldown_failure(failure: &CertificateFailure) -> bool {
    matches!(
        failure.source,
        FailureSource::AcmeAccount
            | FailureSource::AcmeOrder
            | FailureSource::AcmeAuthorization
            | FailureSource::AcmeFinalize
            | FailureSource::CertificateDownload
    )
}

fn fallback_renewal_time(not_before: OffsetDateTime, not_after: OffsetDateTime) -> OffsetDateTime {
    let maximum_jitter_seconds = time::Duration::hours(12).whole_seconds();
    let jitter_seconds = rand::random_range(0..=maximum_jitter_seconds);
    fallback_renewal_time_with_jitter(not_before, not_after, jitter_seconds)
}

fn certificate_policy_matches(
    certificate: &ValidatedCertificate,
    material: &CertifiedMaterial,
) -> bool {
    (certificate.automatic || material.metadata.authority == certificate.authority)
        && certificate_material_challenge_matches(
            &material.metadata.challenge,
            &certificate.challenge,
        )
}

fn automatic_fallback_eligible(failure: &CertificateFailure) -> bool {
    is_authority_cooldown_failure(failure)
        && matches!(
            failure.kind,
            FailureKind::RateLimited | FailureKind::UserActionRequired | FailureKind::Permanent
        )
}

fn automatic_http_only_eligible(
    certificate: &ValidatedCertificate,
    status: &CertificateStatus,
    primary_available: bool,
    fallback_available: bool,
    ever_activated_https: bool,
) -> bool {
    certificate.automatic
        && !ever_activated_https
        && status.active_authority.is_none()
        && !primary_available
        && !fallback_available
        && status.authority == config::CertificateAuthorityKind::Zerossl
        && status
            .failure
            .as_ref()
            .is_some_and(automatic_fallback_eligible)
}

fn certificate_material_challenge_matches(
    active: &config::ChallengeConfig,
    desired: &config::ChallengeConfig,
) -> bool {
    match (active, desired) {
        (config::ChallengeConfig::Http01, config::ChallengeConfig::Http01) => true,
        (
            config::ChallengeConfig::Dns01 {
                provider: active_provider,
                credential_id: active_credential_id,
                ..
            },
            config::ChallengeConfig::Dns01 {
                provider: desired_provider,
                credential_id: desired_credential_id,
                ..
            },
        ) => active_provider == desired_provider && active_credential_id == desired_credential_id,
        _ => false,
    }
}

fn certificate_policy_key(certificate: &ValidatedCertificate) -> String {
    serde_json::to_string(certificate).unwrap_or_else(|_| {
        format!(
            "{}:{:?}:{:?}",
            certificate.id, certificate.authority, certificate.challenge
        )
    })
}

fn empty_certificate_schedule(certificate: &ValidatedCertificate) -> CertificateScheduleJournal {
    CertificateScheduleJournal {
        policy_key: certificate_policy_key(certificate),
        preferred_authority: Some(certificate.authority),
        ever_activated_https: false,
        attempt_count: 0,
        next_renewal_at: None,
        next_attempt_at: None,
        in_flight: false,
        failure: None,
    }
}

fn parse_timestamp(value: &str) -> Option<OffsetDateTime> {
    OffsetDateTime::parse(value, &Rfc3339).ok()
}

fn certificate_availability(material: &CertifiedMaterial) -> CertificateAvailability {
    if material.metadata.not_after > OffsetDateTime::now_utc() {
        CertificateAvailability::Valid
    } else {
        CertificateAvailability::Expired
    }
}

fn simple_failure(
    source: FailureSource,
    kind: FailureKind,
    code: &str,
    message: String,
) -> CertificateFailure {
    CertificateFailure {
        source,
        kind,
        code: code.to_string(),
        message,
        occurred_at: format_timestamp(OffsetDateTime::now_utc()),
        retry_at: None,
        authority: None,
        challenge: None,
        dns_provider: None,
        acme_problem_type: None,
        http_status: None,
    }
}

fn initial_renewal_time(
    certificate: &ValidatedCertificate,
    material: &CertifiedMaterial,
    now: OffsetDateTime,
) -> OffsetDateTime {
    if certificate_policy_matches(certificate, material) {
        fallback_renewal_time(material.metadata.not_before, material.metadata.not_after)
    } else {
        now
    }
}

fn fallback_renewal_time_with_jitter(
    not_before: OffsetDateTime,
    not_after: OffsetDateTime,
    jitter_seconds: i64,
) -> OffsetDateTime {
    let lifetime = not_after - not_before;
    let renewal_lead = std::cmp::min(time::Duration::days(30), lifetime / 3);
    let latest = not_after - time::Duration::seconds(1);
    (not_after - renewal_lead + time::Duration::seconds(jitter_seconds.max(0))).min(latest)
}

fn retry_delay(attempt: u32) -> Duration {
    let base = retry_base_delay(attempt).as_secs();
    let maximum_jitter = (base / 5).min(300);
    let jitter = if base >= RETRY_DELAY_SECONDS[RETRY_DELAY_SECONDS.len() - 1] {
        0
    } else {
        rand::random_range(0..=maximum_jitter)
    };
    Duration::from_secs((base + jitter).min(21_600))
}

fn retry_base_delay(attempt: u32) -> Duration {
    let index = attempt.saturating_sub(1) as usize;
    Duration::from_secs(RETRY_DELAY_SECONDS[index.min(RETRY_DELAY_SECONDS.len() - 1)])
}

fn format_timestamp(timestamp: OffsetDateTime) -> String {
    timestamp
        .format(&Rfc3339)
        .unwrap_or_else(|_| timestamp.unix_timestamp().to_string())
}

async fn run_http_listener(
    listener: TcpListener,
    proxy: Arc<HttpProxy<GatewayProxy>>,
    shutdown: watch::Receiver<bool>,
) {
    run_listener(listener, proxy, None, None, shutdown).await;
}

async fn run_https_listener(
    listener: TcpListener,
    proxy: Arc<HttpProxy<GatewayProxy>>,
    acceptor: Arc<pingora::tls::ssl::SslAcceptor>,
    callbacks: Arc<pingora::listeners::TlsAcceptCallbacks>,
    shutdown: watch::Receiver<bool>,
) {
    run_listener(listener, proxy, Some(acceptor), Some(callbacks), shutdown).await;
}

async fn run_listener(
    listener: TcpListener,
    proxy: Arc<HttpProxy<GatewayProxy>>,
    acceptor: Option<Arc<pingora::tls::ssl::SslAcceptor>>,
    callbacks: Option<Arc<pingora::listeners::TlsAcceptCallbacks>>,
    mut shutdown: watch::Receiver<bool>,
) {
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    break;
                }
            }
            accepted = listener.accept() => {
                match accepted {
                    Ok((stream, peer_addr)) => {
                        let _ = stream.set_nodelay(true);
                        let proxy = proxy.clone();
                        let shutdown = shutdown.clone();
                        let acceptor = acceptor.clone();
                        let callbacks = callbacks.clone();
                        connections.spawn(async move {
                            process_connection(
                                stream,
                                peer_addr,
                                proxy,
                                acceptor,
                                callbacks,
                                shutdown,
                            )
                            .await;
                        });
                    }
                    Err(_) => sleep(Duration::from_millis(100)).await,
                }
            }
            _ = connections.join_next(), if !connections.is_empty() => {}
        }
    }

    if timeout(CONNECTION_SHUTDOWN_TIMEOUT, async {
        while connections.join_next().await.is_some() {}
    })
    .await
    .is_err()
    {
        connections.abort_all();
        while connections.join_next().await.is_some() {}
    }
}

async fn process_connection(
    stream: TcpStream,
    peer_addr: std::net::SocketAddr,
    proxy: Arc<HttpProxy<GatewayProxy>>,
    acceptor: Option<Arc<pingora::tls::ssl::SslAcceptor>>,
    callbacks: Option<Arc<pingora::listeners::TlsAcceptCallbacks>>,
    shutdown: watch::Receiver<bool>,
) {
    let mut l4_stream: l4::stream::Stream = stream.into();
    let socket_digest = SocketDigest::from_raw_fd(l4_stream.as_raw_fd());
    socket_digest
        .peer_addr
        .set(Some(peer_addr.into()))
        .expect("new Gateway connection must not have a peer address yet");
    l4_stream.set_socket_digest(socket_digest);
    let stream: Stream = match (acceptor, callbacks) {
        (Some(acceptor), Some(callbacks)) => {
            let handshake = pingora::protocols::tls::server::handshake_with_callback(
                acceptor.as_ref(),
                l4_stream,
                callbacks.as_ref(),
            );
            match timeout(TLS_HANDSHAKE_TIMEOUT, handshake).await {
                Ok(Ok(stream)) => Box::new(stream),
                Ok(Err(_)) | Err(_) => return,
            }
        }
        (None, None) => Box::new(l4_stream),
        _ => return,
    };
    let _ = proxy.process_new(stream, &shutdown).await;
}

#[cfg(test)]
mod tests {
    use std::{path::Path, sync::Arc};

    use rcgen::{CertificateParams, KeyPair};
    use rustls::{ClientConfig, RootCertStore};
    use rustls_pki_types::{CertificateDer, ServerName};
    use serde_json::{Value, json};
    use tokio::{
        io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
        net::TcpListener,
        sync::oneshot,
    };
    use tokio_rustls::TlsConnector;

    use super::*;

    #[test]
    fn fallback_renewal_uses_one_third_lifetime_with_jitter() {
        let not_before = OffsetDateTime::from_unix_timestamp(1_700_000_000).unwrap();
        let not_after = not_before + time::Duration::days(90);
        let renewal = fallback_renewal_time_with_jitter(not_before, not_after, 3_600);
        assert_eq!(
            renewal,
            not_after - time::Duration::days(30) + time::Duration::hours(1)
        );

        let short_not_after = not_before + time::Duration::hours(1);
        let clamped = fallback_renewal_time_with_jitter(
            not_before,
            short_not_after,
            time::Duration::hours(12).whole_seconds(),
        );
        assert_eq!(clamped, short_not_after - time::Duration::seconds(1));
    }

    #[test]
    fn retry_backoff_reaches_six_hour_cap() {
        let expected = [60, 300, 900, 3_600, 7_200, 14_400, 21_600, 21_600];
        for (attempt, seconds) in (1_u32..).zip(expected) {
            assert_eq!(retry_base_delay(attempt), Duration::from_secs(seconds));
            let delay = retry_delay(attempt);
            assert!(delay >= Duration::from_secs(seconds));
            assert!(delay <= Duration::from_secs(21_600));
        }
    }

    #[test]
    fn dns_rate_limit_does_not_create_an_acme_authority_cooldown() {
        let mut failure = simple_failure(
            FailureSource::DnsProvider,
            FailureKind::RateLimited,
            "cloudflare_rate_limited",
            "Cloudflare rate limited the DNS request".to_string(),
        );
        failure.authority = Some(config::CertificateAuthorityKind::Letsencrypt);
        assert!(!is_authority_cooldown_failure(&failure));

        failure.source = FailureSource::AcmeOrder;
        assert!(is_authority_cooldown_failure(&failure));
    }

    #[test]
    fn automatic_fallback_only_accepts_classified_authority_failures() {
        let mut failure = simple_failure(
            FailureSource::AcmeOrder,
            FailureKind::Permanent,
            "order_failed",
            "order failed".to_string(),
        );
        assert!(automatic_fallback_eligible(&failure));

        failure.kind = FailureKind::Transient;
        assert!(!automatic_fallback_eligible(&failure));

        failure.kind = FailureKind::Permanent;
        failure.source = FailureSource::DnsPropagation;
        assert!(!automatic_fallback_eligible(&failure));
    }

    #[test]
    fn http_only_requires_initial_automatic_ca_exhaustion() {
        let certificate = ValidatedCertificate {
            id: "automatic".to_string(),
            domains: vec!["*.node.example.com".to_string()],
            authority: config::CertificateAuthorityKind::Letsencrypt,
            challenge: config::ChallengeConfig::Dns01 {
                provider: config::DnsProviderKind::Cloudflare,
                credential_id: "dns".to_string(),
                credential_revision: 1,
            },
            automatic: true,
            renewal_enabled: true,
        };
        let mut status = CertificateStatus::pending(
            certificate.id.clone(),
            certificate.domains.clone(),
            config::CertificateAuthorityKind::Zerossl,
            "DNS-01".to_string(),
        );
        status.failure = Some(simple_failure(
            FailureSource::AcmeOrder,
            FailureKind::Permanent,
            "order_failed",
            "ZeroSSL rejected the order".to_string(),
        ));

        assert!(automatic_http_only_eligible(
            &certificate,
            &status,
            false,
            false,
            false
        ));
        assert!(!automatic_http_only_eligible(
            &certificate,
            &status,
            false,
            false,
            true
        ));
        assert!(!automatic_http_only_eligible(
            &certificate,
            &status,
            true,
            false,
            false
        ));
        assert!(!automatic_http_only_eligible(
            &certificate,
            &status,
            false,
            true,
            false
        ));

        status.failure = Some(simple_failure(
            FailureSource::DnsProvider,
            FailureKind::Permanent,
            "dns_failed",
            "DNS validation failed".to_string(),
        ));
        assert!(!automatic_http_only_eligible(
            &certificate,
            &status,
            false,
            false,
            false
        ));

        status.failure = Some(simple_failure(
            FailureSource::AcmeOrder,
            FailureKind::Transient,
            "network_failed",
            "The ACME request timed out".to_string(),
        ));
        assert!(!automatic_http_only_eligible(
            &certificate,
            &status,
            false,
            false,
            false
        ));
    }

    #[test]
    fn changing_certificate_policy_resets_the_acme_attempt() {
        let certificate_id = "gateway-cert".to_string();
        let current = BTreeMap::from([(
            certificate_id.clone(),
            ValidatedCertificate {
                id: certificate_id.clone(),
                domains: vec!["gateway.test".to_string()],
                authority: config::CertificateAuthorityKind::Letsencrypt,
                challenge: config::ChallengeConfig::Http01,
                automatic: false,
                renewal_enabled: true,
            },
        )]);
        let next_certificate = ValidatedCertificate {
            id: certificate_id.clone(),
            domains: vec!["gateway.test".to_string()],
            authority: config::CertificateAuthorityKind::Letsencrypt,
            challenge: config::ChallengeConfig::Dns01 {
                provider: DnsProviderKind::Aliyun,
                credential_id: "aliyun-main".to_string(),
                credential_revision: 1,
            },
            automatic: false,
            renewal_enabled: true,
        };
        let next = BTreeMap::from([(certificate_id.clone(), next_certificate.clone())]);

        assert_eq!(
            changed_certificate_ids(&current, &next),
            [certificate_id.clone()]
        );
        let stale_output = AcmeJobOutput {
            certificate_id: "gateway-cert".to_string(),
            attempted_certificate: current["gateway-cert"].clone(),
            result: Err(simple_failure(
                FailureSource::AcmeAuthorization,
                FailureKind::UserActionRequired,
                "unauthorized",
                "HTTP-01 authorization failed".to_string(),
            )),
            cleanup_failures: Vec::new(),
            cleanup_journal_error: None,
        };
        assert!(!stale_output.matches(&next_certificate));

        let changed_authority = ValidatedCertificate {
            authority: config::CertificateAuthorityKind::Zerossl,
            challenge: config::ChallengeConfig::Http01,
            ..current["gateway-cert"].clone()
        };
        assert_eq!(
            changed_certificate_ids(
                &current,
                &BTreeMap::from([(certificate_id, changed_authority.clone())])
            ),
            ["gateway-cert"]
        );
        assert!(!stale_output.matches(&changed_authority));
    }

    #[test]
    fn stored_certificate_with_a_different_policy_renews_immediately() {
        let domains = ["gateway.test"];
        let (certificate_pem, private_key_pem, _) = test_certificate(&domains);
        let material = CertifiedMaterial::from_pem_with_policy(
            &certificate_pem,
            &private_key_pem,
            &[domains[0].to_string()],
            config::CertificateAuthorityKind::Letsencrypt,
            config::ChallengeConfig::Http01,
        )
        .unwrap();
        let configured = ValidatedCertificate {
            id: "gateway-cert".to_string(),
            domains: vec![domains[0].to_string()],
            authority: config::CertificateAuthorityKind::Zerossl,
            challenge: config::ChallengeConfig::Dns01 {
                provider: DnsProviderKind::Cloudflare,
                credential_id: "cloudflare-main".to_string(),
                credential_revision: 1,
            },
            automatic: false,
            renewal_enabled: true,
        };
        let now = OffsetDateTime::now_utc();

        assert_eq!(initial_renewal_time(&configured, &material, now), now);
        assert!(!certificate_policy_matches(&configured, &material));
    }

    #[test]
    fn dns_credential_revision_invalidates_attempt_state_without_replacing_valid_material() {
        let domains = ["gateway.test"];
        let (certificate_pem, private_key_pem, _) = test_certificate(&domains);
        let active_certificate = ValidatedCertificate {
            id: "gateway-cert".to_string(),
            domains: vec![domains[0].to_string()],
            authority: config::CertificateAuthorityKind::Letsencrypt,
            challenge: config::ChallengeConfig::Dns01 {
                provider: DnsProviderKind::Cloudflare,
                credential_id: "cloudflare-main".to_string(),
                credential_revision: 1,
            },
            automatic: false,
            renewal_enabled: true,
        };
        let material = CertifiedMaterial::from_pem_with_policy(
            &certificate_pem,
            &private_key_pem,
            &active_certificate.domains,
            active_certificate.authority,
            active_certificate.challenge.clone(),
        )
        .unwrap();
        let desired_certificate = ValidatedCertificate {
            challenge: config::ChallengeConfig::Dns01 {
                provider: DnsProviderKind::Cloudflare,
                credential_id: "cloudflare-main".to_string(),
                credential_revision: 2,
            },
            ..active_certificate.clone()
        };

        assert_eq!(
            changed_certificate_ids(
                &BTreeMap::from([(active_certificate.id.clone(), active_certificate.clone())]),
                &BTreeMap::from([(desired_certificate.id.clone(), desired_certificate.clone())])
            ),
            ["gateway-cert"]
        );
        assert!(certificate_policy_matches(&desired_certificate, &material));
    }

    #[test]
    fn gateway_runs_without_published_services() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let temp = tempfile::tempdir().unwrap();
            let config = json!({
                "schema_version": 7,
                "deployment": {
                    "configuration_id": "00000000-0000-0000-0000-000000000000",
                    "revision": 0,
                    "fingerprint": "empty-gateway-test"
                },
                "storage_dir": temp.path().join("gateway"),
                "listeners": {
                    "http": "127.0.0.1:0",
                    "https": "127.0.0.1:0",
                    "dns": "127.0.0.1:0"
                },
                "local_dns": {
                    "domains": [],
                    "answer_ipv4": "127.0.0.1",
                    "ttl": 30
                },
                "acme": {
                    "contact_email": null,
                    "terms_of_service_agreed": false
                },
                "certificates": [],
                "routes": []
            });
            let gateway = GatewayHandle::start(&config.to_string(), &empty_secrets().to_string())
                .await
                .unwrap();
            let status: Value = serde_json::from_str(&gateway.status_json().unwrap()).unwrap();
            assert_eq!(status["state"], "running");
            assert!(status["certificates"].as_array().unwrap().is_empty());
            assert!(status["routes"].as_array().unwrap().is_empty());

            let response = plain_http_request(
                status["listeners"]["http"].as_str().unwrap(),
                "unknown.gateway.test",
                "/",
            )
            .await;
            assert!(response.starts_with("HTTP/1.1 404"), "{response:?}");
            gateway.stop().await.unwrap();
        });
    }

    #[test]
    fn applying_an_added_route_preserves_existing_route_runtime_state() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let temp = tempfile::tempdir().unwrap();
            let storage_dir = temp.path().join("gateway");
            let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let upstream_addr = upstream.local_addr().unwrap();
            let existing_domain = "existing.gateway.test";
            let added_domain = "added.gateway.test";

            let config = gateway_config(
                &storage_dir,
                upstream_addr,
                &[existing_domain],
                "127.0.0.1:0",
                "127.0.0.1:0",
            );
            let gateway = GatewayHandle::start(&config.to_string(), &empty_secrets().to_string())
                .await
                .unwrap();
            let existing_route = gateway.routes.snapshot().get(existing_domain).unwrap();
            assert_eq!(existing_route.resolve_for_test().await, Some(upstream_addr));
            let status_before = existing_route.status(existing_domain, "gateway-cert");
            assert_eq!(
                status_before.resolution_state,
                status::RouteResolutionState::Ready
            );

            let mut updated = gateway_config(
                &storage_dir,
                upstream_addr,
                &[existing_domain, added_domain],
                "127.0.0.1:0",
                "127.0.0.1:0",
            );
            updated["deployment"]["revision"] = json!(1);
            updated["deployment"]["fingerprint"] = json!("route-added");
            gateway
                .apply_config(&updated.to_string(), None)
                .await
                .unwrap();

            let route_after = gateway.routes.snapshot().get(existing_domain).unwrap();
            let status_after = route_after.status(existing_domain, "gateway-cert");
            assert!(Arc::ptr_eq(&existing_route, &route_after));
            assert_eq!(
                status_after.resolution_state,
                status_before.resolution_state
            );
            assert_eq!(
                status_after.resolved_addresses,
                status_before.resolved_addresses
            );
            assert_eq!(
                status_after.last_resolved_at,
                status_before.last_resolved_at
            );
            assert_eq!(status_after.last_online_at, status_before.last_online_at);

            let added_route = gateway.routes.snapshot().get(added_domain).unwrap();
            let mut certificate_updated = updated.clone();
            let mut alternate_certificate = certificate_updated["certificates"][0].clone();
            alternate_certificate["id"] = json!("alternate-cert");
            certificate_updated["certificates"]
                .as_array_mut()
                .unwrap()
                .push(alternate_certificate);
            certificate_updated["routes"]
                .as_array_mut()
                .unwrap()
                .iter_mut()
                .find(|route| route["domain"] == existing_domain)
                .unwrap()["certificate_id"] = json!("alternate-cert");
            certificate_updated["deployment"]["revision"] = json!(2);
            certificate_updated["deployment"]["fingerprint"] = json!("certificate-changed");
            gateway
                .apply_config(&certificate_updated.to_string(), None)
                .await
                .unwrap();

            let existing_after_certificate_change =
                gateway.routes.snapshot().get(existing_domain).unwrap();
            assert!(Arc::ptr_eq(
                &existing_route,
                &existing_after_certificate_change
            ));
            let route_status = gateway
                .routes
                .statuses()
                .into_iter()
                .find(|route| route.domain == existing_domain)
                .unwrap();
            assert_eq!(route_status.certificate_id, "alternate-cert");

            let changed_upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let changed_upstream_addr = changed_upstream.local_addr().unwrap();
            let mut upstream_updated = certificate_updated.clone();
            upstream_updated["routes"]
                .as_array_mut()
                .unwrap()
                .iter_mut()
                .find(|route| route["domain"] == added_domain)
                .unwrap()["upstream"]["url"] = json!(format!("http://{changed_upstream_addr}"));
            upstream_updated["deployment"]["revision"] = json!(3);
            upstream_updated["deployment"]["fingerprint"] = json!("upstream-changed");
            gateway
                .apply_config(&upstream_updated.to_string(), None)
                .await
                .unwrap();

            let routes_after_upstream_change = gateway.routes.snapshot();
            assert!(Arc::ptr_eq(
                &existing_route,
                &routes_after_upstream_change.get(existing_domain).unwrap()
            ));
            let changed_added_route = routes_after_upstream_change.get(added_domain).unwrap();
            assert!(!Arc::ptr_eq(&added_route, &changed_added_route));

            let mut deleted = gateway_config(
                &storage_dir,
                upstream_addr,
                &[existing_domain],
                "127.0.0.1:0",
                "127.0.0.1:0",
            );
            deleted["deployment"]["revision"] = json!(4);
            deleted["deployment"]["fingerprint"] = json!("route-deleted");
            gateway
                .apply_config(&deleted.to_string(), None)
                .await
                .unwrap();

            let routes_after_delete = gateway.routes.snapshot();
            assert!(Arc::ptr_eq(
                &existing_route,
                &routes_after_delete.get(existing_domain).unwrap()
            ));
            assert!(routes_after_delete.get(added_domain).is_none());
            assert_eq!(
                changed_added_route.resolve_for_test().await,
                Some(changed_upstream_addr)
            );

            gateway.stop().await.unwrap();
        });
    }

    #[test]
    fn gateway_routes_tls_and_enforces_http_policy() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let temp = tempfile::tempdir().unwrap();
            let storage_dir = temp.path().join("gateway");
            let domains = ["app.gateway.test", "other.gateway.test"];
            let (certificate_pem, private_key_pem, certificate_der) = test_certificate(&domains);
            let stored_certificate = ValidatedCertificate {
                id: "gateway-cert".to_string(),
                domains: domains.iter().map(|domain| domain.to_string()).collect(),
                authority: config::CertificateAuthorityKind::Letsencrypt,
                challenge: config::ChallengeConfig::Http01,
                automatic: false,
                renewal_enabled: true,
            };
            GatewayStorage::initialize(storage_dir.clone())
                .unwrap()
                .store_certificate(&stored_certificate, &certificate_pem, &private_key_pem)
                .unwrap();

            let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let upstream_addr = upstream.local_addr().unwrap();
            let (request_sender, request_receiver) = oneshot::channel();
            let upstream_task = tokio::spawn(async move {
                let (mut stream, _) = upstream.accept().await.unwrap();
                let request = read_http_headers(&mut stream).await;
                let _ = request_sender.send(request);
                stream
                    .write_all(
                        b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nproxied",
                    )
                    .await
                    .unwrap();
            });

            let config = gateway_config(
                &storage_dir,
                upstream_addr,
                &domains,
                "127.0.0.1:0",
                "127.0.0.1:0",
            );
            let gateway = GatewayHandle::start(&config.to_string(), &empty_secrets().to_string())
                .await
                .unwrap();
            let status: Value = serde_json::from_str(&gateway.status_json().unwrap()).unwrap();
            assert_eq!(status["state"], "running");
            assert_eq!(status["certificates"][0]["availability"], "valid");
            assert_eq!(status["certificates"][0]["operation"], "idle");
            let http_addr = status["listeners"]["http"].as_str().unwrap();
            let https_addr = status["listeners"]["https"].as_str().unwrap();

            let redirect = plain_http_request(http_addr, domains[0], "/hello?q=1").await;
            assert!(redirect.starts_with("HTTP/1.1 308"), "{redirect:?}");
            assert!(
                redirect
                    .to_ascii_lowercase()
                    .contains("location: https://app.gateway.test/hello?q=1")
            );

            gateway.routes.mark_unavailable_for_test(domains[0]);
            let unavailable_status: Value =
                serde_json::from_str(&gateway.status_json().unwrap()).unwrap();
            let unavailable_route = unavailable_status["routes"]
                .as_array()
                .unwrap()
                .iter()
                .find(|route| route["domain"] == domains[0])
                .unwrap();
            assert_eq!(unavailable_route["resolution_state"], "unavailable");

            let proxied = tls_http_request(
                https_addr,
                domains[0],
                domains[0],
                "/through-gateway",
                certificate_der.clone(),
            )
            .await;
            assert!(proxied.starts_with("HTTP/1.1 200"));
            assert!(proxied.ends_with("proxied"));
            let upstream_request = request_receiver.await.unwrap().to_ascii_lowercase();
            assert!(upstream_request.contains("host: app.gateway.test"));
            assert!(upstream_request.contains("x-forwarded-proto: https"));
            assert!(upstream_request.contains("x-forwarded-host: app.gateway.test"));

            let recovered_status: Value =
                serde_json::from_str(&gateway.status_json().unwrap()).unwrap();
            let recovered_route = recovered_status["routes"]
                .as_array()
                .unwrap()
                .iter()
                .find(|route| route["domain"] == domains[0])
                .unwrap();
            assert_eq!(recovered_route["resolution_state"], "ready");

            let mut stale_status = gateway.status.load_full().as_ref().clone();
            let stale_route = stale_status
                .routes
                .iter_mut()
                .find(|route| route.domain == domains[0])
                .unwrap();
            stale_route.resolution_state = status::RouteResolutionState::Resolving;
            stale_route.resolved_addresses.clear();
            stale_route.last_resolved_at = None;
            gateway.status.store(Arc::new(stale_status));

            let refreshed_status: Value =
                serde_json::from_str(&gateway.status_json().unwrap()).unwrap();
            let resolved_route = refreshed_status["routes"]
                .as_array()
                .unwrap()
                .iter()
                .find(|route| route["domain"] == domains[0])
                .unwrap();
            assert_eq!(resolved_route["resolution_state"], "ready");
            assert_eq!(
                resolved_route["resolved_addresses"],
                json!([upstream_addr.to_string()])
            );

            let mismatch =
                tls_http_request(https_addr, domains[0], domains[1], "/", certificate_der).await;
            assert!(mismatch.starts_with("HTTP/1.1 421"));
            assert!(mismatch.contains("TLS SNI and HTTP Host do not match"));

            gateway.stop().await.unwrap();
            upstream_task.await.unwrap();
        });
    }

    #[test]
    fn gateway_returns_503_until_certificate_is_ready() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let temp = tempfile::tempdir().unwrap();
            let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let config = gateway_config(
                &temp.path().join("gateway"),
                upstream.local_addr().unwrap(),
                &["pending.gateway.test"],
                "127.0.0.1:0",
                "127.0.0.1:0",
            );
            let gateway = GatewayHandle::start(&config.to_string(), &empty_secrets().to_string())
                .await
                .unwrap();
            let status: Value = serde_json::from_str(&gateway.status_json().unwrap()).unwrap();
            let http_addr = status["listeners"]["http"].as_str().unwrap();

            gateway.challenges.insert(
                "pending.gateway.test".to_string(),
                "http01-token".to_string(),
                "http01-key-authorization".to_string(),
            );
            let challenge = plain_http_request(
                http_addr,
                "pending.gateway.test",
                "/.well-known/acme-challenge/http01-token",
            )
            .await;
            assert!(challenge.starts_with("HTTP/1.1 200"));
            assert!(challenge.ends_with("http01-key-authorization"));
            gateway
                .challenges
                .remove("pending.gateway.test", "http01-token");

            let response = plain_http_request(http_addr, "pending.gateway.test", "/").await;
            assert!(response.starts_with("HTTP/1.1 503"), "{response:?}");
            assert!(response.to_ascii_lowercase().contains("retry-after: 30"));

            let unknown = plain_http_request(http_addr, "unknown.gateway.test", "/").await;
            assert!(unknown.starts_with("HTTP/1.1 404"));
            gateway.stop().await.unwrap();
        });
    }

    #[test]
    fn gateway_routes_http2_authority() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let temp = tempfile::tempdir().unwrap();
            let storage_dir = temp.path().join("gateway");
            let domain = "h2.gateway.test";
            let (certificate_pem, private_key_pem, certificate_der) =
                test_certificate(&[domain]);
            let stored_certificate = ValidatedCertificate {
                id: "gateway-cert".to_string(),
                domains: vec![domain.to_string()],
                authority: config::CertificateAuthorityKind::Letsencrypt,
                challenge: config::ChallengeConfig::Http01,
                automatic: false,
                renewal_enabled: true,
            };
            GatewayStorage::initialize(storage_dir.clone())
                .unwrap()
                .store_certificate(
                    &stored_certificate,
                    &certificate_pem,
                    &private_key_pem,
                )
                .unwrap();

            let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let upstream_addr = upstream.local_addr().unwrap();
            let (request_sender, request_receiver) = oneshot::channel();
            let upstream_task = tokio::spawn(async move {
                let (mut stream, _) = upstream.accept().await.unwrap();
                let request = read_http_headers(&mut stream).await;
                let _ = request_sender.send(request);
                stream
                    .write_all(
                        b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\nh2-proxied",
                    )
                    .await
                    .unwrap();
            });

            let config = gateway_config(
                &storage_dir,
                upstream_addr,
                &[domain],
                "127.0.0.1:0",
                "127.0.0.1:0",
            );
            let gateway = GatewayHandle::start(&config.to_string(), &empty_secrets().to_string())
                .await
                .unwrap();
            let status: Value = serde_json::from_str(&gateway.status_json().unwrap()).unwrap();
            let https_addr = status["listeners"]["https"].as_str().unwrap();

            let (response_status, response_body) =
                tls_h2_request(https_addr, domain, "/through-h2", certificate_der).await;
            assert_eq!(response_status, http::StatusCode::OK);
            assert_eq!(response_body, "h2-proxied");

            let upstream_request = request_receiver.await.unwrap().to_ascii_lowercase();
            assert!(upstream_request.contains("host: h2.gateway.test"));
            assert!(upstream_request.contains("x-forwarded-proto: https"));
            assert!(upstream_request.contains("x-forwarded-host: h2.gateway.test"));

            gateway.stop().await.unwrap();
            upstream_task.await.unwrap();
        });
    }

    fn gateway_config(
        storage_dir: &Path,
        upstream_addr: std::net::SocketAddr,
        domains: &[&str],
        http_listener: &str,
        https_listener: &str,
    ) -> Value {
        json!({
            "schema_version": 7,
            "deployment": {
                "configuration_id": "00000000-0000-0000-0000-000000000000",
                "revision": 0,
                "fingerprint": "gateway-test"
            },
            "storage_dir": storage_dir,
            "listeners": {
                "http": http_listener,
                "https": https_listener,
                "dns": "127.0.0.1:0"
            },
            "local_dns": {
                "domains": domains,
                "answer_ipv4": "127.0.0.1",
                "ttl": 30
            },
            "acme": {
                "contact_email": "gateway@example.com",
                "accepted_authorities": ["letsencrypt"]
            },
            "certificates": [{
                "id": "gateway-cert",
                "domains": domains,
                "strategy": {
                    "type": "custom",
                    "authority": "letsencrypt",
                    "challenge": { "type": "http01" }
                }
            }],
            "routes": domains.iter().map(|domain| json!({
                "domain": domain,
                "certificate_id": "gateway-cert",
                "upstream": {
                    "url": format!("http://{upstream_addr}"),
                    "host_header": null,
                    "tls_server_name": null,
                    "allowed_ipv4_cidr": null,
                    "availability": "ready",
                    "expected_ipv4": null
                }
            })).collect::<Vec<_>>()
        })
    }

    fn empty_secrets() -> Value {
        json!({ "schema_version": 7, "cloudflare": {}, "aliyun": {} })
    }

    fn test_certificate(domains: &[&str]) -> (String, String, CertificateDer<'static>) {
        let mut params = CertificateParams::new(
            domains
                .iter()
                .map(|domain| domain.to_string())
                .collect::<Vec<_>>(),
        )
        .unwrap();
        params.not_before = OffsetDateTime::now_utc() - time::Duration::days(1);
        params.not_after = OffsetDateTime::now_utc() + time::Duration::days(90);
        let key = KeyPair::generate().unwrap();
        let certificate = params.self_signed(&key).unwrap();
        (
            certificate.pem(),
            key.serialize_pem(),
            CertificateDer::from(certificate.der().to_vec()),
        )
    }

    async fn plain_http_request(address: &str, host: &str, path: &str) -> String {
        let stream = TcpStream::connect(address).await.unwrap();
        send_http_request(stream, host, path).await
    }

    async fn tls_http_request(
        address: &str,
        server_name: &str,
        host: &str,
        path: &str,
        root_certificate: CertificateDer<'static>,
    ) -> String {
        let mut roots = RootCertStore::empty();
        roots.add(root_certificate).unwrap();
        let mut config = ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        config.alpn_protocols = vec![b"http/1.1".to_vec()];
        let connector = TlsConnector::from(Arc::new(config));
        let stream = TcpStream::connect(address).await.unwrap();
        let server_name = ServerName::try_from(server_name.to_string()).unwrap();
        let stream = connector.connect(server_name, stream).await.unwrap();
        send_http_request(stream, host, path).await
    }

    async fn tls_h2_request(
        address: &str,
        server_name: &str,
        path: &str,
        root_certificate: CertificateDer<'static>,
    ) -> (http::StatusCode, String) {
        let mut roots = RootCertStore::empty();
        roots.add(root_certificate).unwrap();
        let mut config = ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        config.alpn_protocols = vec![b"h2".to_vec()];
        let connector = TlsConnector::from(Arc::new(config));
        let stream = TcpStream::connect(address).await.unwrap();
        let tls_server_name = ServerName::try_from(server_name.to_string()).unwrap();
        let stream = connector.connect(tls_server_name, stream).await.unwrap();
        assert_eq!(stream.get_ref().1.alpn_protocol(), Some(b"h2".as_slice()));

        let (client, connection) = h2::client::handshake(stream).await.unwrap();
        let connection_task = tokio::spawn(async move { connection.await });
        let request = http::Request::builder()
            .method(http::Method::GET)
            .uri(format!("https://{server_name}{path}"))
            .body(())
            .unwrap();
        let (response, _) = client
            .ready()
            .await
            .unwrap()
            .send_request(request, true)
            .unwrap();
        let response = response.await.unwrap();
        let status = response.status();
        let mut body = response.into_body();
        let mut bytes = Vec::new();
        while let Some(chunk) = body.data().await {
            bytes.extend_from_slice(&chunk.unwrap());
        }
        connection_task.abort();

        (status, String::from_utf8(bytes).unwrap())
    }

    async fn send_http_request<S>(mut stream: S, host: &str, path: &str) -> String
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        stream
            .write_all(
                format!("GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n")
                    .as_bytes(),
            )
            .await
            .unwrap();
        let mut response = Vec::new();
        timeout(Duration::from_secs(5), stream.read_to_end(&mut response))
            .await
            .unwrap()
            .unwrap();
        String::from_utf8(response).unwrap()
    }

    async fn read_http_headers<S>(stream: &mut S) -> String
    where
        S: AsyncRead + Unpin,
    {
        let mut request = Vec::new();
        let mut buffer = [0_u8; 1_024];
        loop {
            let count = stream.read(&mut buffer).await.unwrap();
            if count == 0 {
                break;
            }
            request.extend_from_slice(&buffer[..count]);
            if request.windows(4).any(|window| window == b"\r\n\r\n") {
                break;
            }
        }
        String::from_utf8(request).unwrap()
    }
}
