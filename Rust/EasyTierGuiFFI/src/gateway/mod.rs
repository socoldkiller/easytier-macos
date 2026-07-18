mod acme;
mod config;
mod proxy;
mod status;
mod storage;
mod tls;

use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Arc,
    time::Duration,
};

use arc_swap::ArcSwap;
use pingora::{
    apps::ServerApp,
    protocols::{Stream, l4},
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

use acme::{AcmeContext, AcmeJobOutput};
use config::{ChallengeConfig, GATEWAY_SCHEMA_VERSION, ValidatedGatewayConfig};
use proxy::{GatewayProxy, Http01ChallengeStore, SharedRouteTable, resolve_route_table};
use status::{CertificateState, CertificateStatus, GatewayState, ListenerStatus};
use storage::{GatewayStorage, PendingDnsCleanup};
use tls::{DynamicCertificateStore, build_tls_acceptor};

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
            config,
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
        serde_json::to_string(self.status.load().as_ref())
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
}

impl RuntimeSecrets {
    fn from_input(secrets: GatewaySecrets) -> Self {
        Self {
            cloudflare: secrets
                .cloudflare
                .into_iter()
                .map(|(id, secret)| (id, Zeroizing::new(secret.api_token)))
                .collect(),
        }
    }

    fn validate_references(&self, config: &ValidatedGatewayConfig) -> Result<(), String> {
        for certificate in config.certificates.values() {
            if let Some(credential_id) = certificate.challenge.credential_id()
                && !self.cloudflare.contains_key(credential_id)
            {
                return Err(format!(
                    "certificate {} references missing Cloudflare credential {credential_id}",
                    certificate.id
                ));
            }
        }
        Ok(())
    }

    fn cloudflare_token(&self, credential_id: &str) -> Option<Zeroizing<String>> {
        self.cloudflare
            .get(credential_id)
            .map(|token| Zeroizing::new(token.as_str().to_string()))
    }
}

enum GatewayCommand {
    Apply {
        config: ValidatedGatewayConfig,
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
    JobFinished(AcmeJobOutput),
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
    routes: Arc<SharedRouteTable>,
    proxy: Arc<HttpProxy<GatewayProxy>>,
    shutdown: watch::Sender<bool>,
    listener_tasks: Vec<JoinHandle<()>>,
    status: Arc<ArcSwap<GatewayStatusSnapshot>>,
    certificate_status: BTreeMap<String, CertificateStatus>,
    listener_status: ListenerStatus,
    config_generation: u64,
    queued_certificates: BTreeSet<String>,
    in_flight_certificates: BTreeSet<String>,
    ari_in_flight: BTreeSet<String>,
    renewal_at: BTreeMap<String, OffsetDateTime>,
    retry_attempts: BTreeMap<String, u32>,
    pending_cleanups: Vec<PendingDnsCleanup>,
    cleanup_in_flight: bool,
    background_tasks: Vec<JoinHandle<()>>,
}

impl GatewayInstance {
    async fn start(
        config: ValidatedGatewayConfig,
        secrets: RuntimeSecrets,
    ) -> Result<GatewayHandle, String> {
        let storage = GatewayStorage::initialize(config.source.storage_dir.clone())?;
        let pending_cleanups = storage.load_cleanup_journal()?;
        let certificates = DynamicCertificateStore::new();
        certificates.update_routes(&config);
        let challenges = Http01ChallengeStore::new();
        let acme = AcmeContext::new(
            config.source.acme.clone(),
            storage.clone(),
            challenges.clone(),
        );
        let (acme_event_sender, acme_events) = mpsc::unbounded_channel();
        let route_table = resolve_route_table(&config).await?;
        let routes = SharedRouteTable::new(route_table);

        let mut certificate_status = BTreeMap::new();
        for certificate in config.certificates.values() {
            let mut status = CertificateStatus::pending(
                certificate.id.clone(),
                certificate.domains.clone(),
                certificate.challenge.kind().to_string(),
            );
            match storage.load_certificate(&certificate.id, &certificate.domains) {
                Ok(Some(material)) => {
                    status.state = CertificateState::Active;
                    status.not_before = Some(material.metadata.not_before_rfc3339.clone());
                    status.not_after = Some(material.metadata.not_after_rfc3339.clone());
                    certificates.install(certificate.id.clone(), material);
                }
                Ok(None) => {}
                Err(error) => {
                    status.state = CertificateState::Failed;
                    status.last_error = Some(error);
                }
            }
            certificate_status.insert(certificate.id.clone(), status);
        }

        let mut server_conf = ServerConf::default();
        server_conf.threads = 1;
        server_conf.upstream_keepalive_pool_size = 128;
        server_conf.max_retries = 1;
        let server_conf = Arc::new(server_conf);
        let gateway_proxy =
            GatewayProxy::new(routes.clone(), certificates.clone(), challenges.clone());
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
            shutdown_watch,
        ));

        let status = Arc::new(ArcSwap::from_pointee(GatewayStatusSnapshot::default()));
        let listener_status = ListenerStatus {
            http: Some(http_addr.to_string()),
            https: Some(https_addr.to_string()),
        };
        let mut instance = Self {
            config,
            secrets,
            storage,
            acme,
            acme_events,
            acme_event_sender,
            certificates,
            routes,
            proxy,
            shutdown,
            listener_tasks: vec![http_task, https_task],
            status: status.clone(),
            certificate_status,
            listener_status,
            config_generation: 1,
            queued_certificates: BTreeSet::new(),
            in_flight_certificates: BTreeSet::new(),
            ari_in_flight: BTreeSet::new(),
            renewal_at: BTreeMap::new(),
            retry_attempts: BTreeMap::new(),
            pending_cleanups,
            cleanup_in_flight: false,
            background_tasks: Vec::new(),
        };
        instance.initialize_renewal_schedule();
        instance.enqueue_due_certificates();
        instance.drain_certificate_queue();
        instance.retry_pending_cleanups();
        instance.publish_status(GatewayState::Running, None);

        let (commands, receiver) = mpsc::channel(16);
        tokio::spawn(instance.run(receiver));
        Ok(GatewayHandle {
            commands,
            status,
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
                            let result = self.apply(config, secrets).await;
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
        let changed_certificate_ids = config
            .certificates
            .iter()
            .filter(|(certificate_id, certificate)| {
                self.config
                    .certificates
                    .get(*certificate_id)
                    .is_some_and(|current| current.domains != certificate.domains)
            })
            .map(|(certificate_id, _)| certificate_id.clone())
            .collect::<Vec<_>>();
        match secrets.as_ref() {
            Some(secrets) => secrets.validate_references(&config)?,
            None => self.secrets.validate_references(&config)?,
        }

        let route_table = resolve_route_table(&config).await?;
        self.acme.update_config(config.source.acme.clone()).await?;
        let mut next_status = BTreeMap::new();
        for certificate in config.certificates.values() {
            let status = if let Some(status) = self.certificate_status.get(&certificate.id)
                && status.domains == certificate.domains
                && status.challenge == certificate.challenge.kind()
            {
                status.clone()
            } else {
                match self
                    .storage
                    .load_certificate(&certificate.id, &certificate.domains)
                {
                    Ok(Some(material)) => {
                        self.certificates
                            .install(certificate.id.clone(), material.clone());
                        CertificateStatus {
                            id: certificate.id.clone(),
                            domains: certificate.domains.clone(),
                            challenge: certificate.challenge.kind().to_string(),
                            state: CertificateState::Active,
                            not_before: Some(material.metadata.not_before_rfc3339.clone()),
                            not_after: Some(material.metadata.not_after_rfc3339.clone()),
                            next_renewal_at: None,
                            last_attempt_at: None,
                            last_error: None,
                        }
                    }
                    Ok(None) => CertificateStatus::pending(
                        certificate.id.clone(),
                        certificate.domains.clone(),
                        certificate.challenge.kind().to_string(),
                    ),
                    Err(error) => {
                        let mut status = CertificateStatus::pending(
                            certificate.id.clone(),
                            certificate.domains.clone(),
                            certificate.challenge.kind().to_string(),
                        );
                        status.state = CertificateState::Failed;
                        status.last_error = Some(error);
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
        self.routes.replace(route_table);
        self.certificate_status = next_status;
        self.config = config;
        self.config_generation = self.config_generation.saturating_add(1);
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
        self.initialize_renewal_schedule();
        self.enqueue_due_certificates();
        self.drain_certificate_queue();
        self.retry_pending_cleanups();
        self.publish_status(GatewayState::Running, None);
        Ok(())
    }

    fn initialize_renewal_schedule(&mut self) {
        let now = OffsetDateTime::now_utc();
        let certificate_ids = self.config.certificates.keys().cloned().collect::<Vec<_>>();
        for certificate_id in certificate_ids {
            if let Some(renewal_at) = self.renewal_at.get(&certificate_id).copied() {
                self.update_next_renewal_status(&certificate_id, renewal_at);
                continue;
            }

            match self.certificates.get(&certificate_id) {
                Some(material) => {
                    let renewal_at = fallback_renewal_time(
                        material.metadata.not_before,
                        material.metadata.not_after,
                    );
                    self.set_renewal_time(&certificate_id, renewal_at);
                    self.request_ari(&certificate_id, material);
                }
                None => self.set_renewal_time(&certificate_id, now),
            }
        }
    }

    fn enqueue_due_certificates(&mut self) {
        let now = OffsetDateTime::now_utc();
        let due = self
            .renewal_at
            .iter()
            .filter(|(certificate_id, renewal_at)| {
                **renewal_at <= now
                    && self.config.certificates.contains_key(*certificate_id)
                    && !self.in_flight_certificates.contains(*certificate_id)
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
            let cloudflare_token = match &certificate.challenge {
                ChallengeConfig::Http01 => None,
                ChallengeConfig::Dns01 { credential_id, .. } => {
                    match self.secrets.cloudflare_token(credential_id) {
                        Some(token) => Some(token),
                        None => {
                            self.record_issuance_failure(
                                &certificate_id,
                                format!(
                                    "Cloudflare credential {credential_id} is unavailable for certificate {certificate_id}"
                                ),
                            );
                            continue;
                        }
                    }
                }
            };

            let current = self.certificates.get(&certificate_id);
            let current_leaf_der = current
                .as_ref()
                .map(|material| material.metadata.leaf_der.clone());
            if let Some(status) = self.certificate_status.get_mut(&certificate_id) {
                status.state = if current.is_some() {
                    CertificateState::Renewing
                } else {
                    CertificateState::Issuing
                };
                status.last_attempt_at = Some(format_timestamp(OffsetDateTime::now_utc()));
                status.last_error = None;
            }
            self.in_flight_certificates.insert(certificate_id.clone());

            let acme = self.acme.clone();
            let events = self.acme_event_sender.clone();
            let cancellation = self.shutdown.subscribe();
            self.background_tasks.push(tokio::spawn(async move {
                let output = acme
                    .issue(
                        certificate,
                        cloudflare_token,
                        current_leaf_der,
                        cancellation,
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

        let attempted = self.pending_cleanups.clone();
        let tokens = attempted
            .iter()
            .filter_map(|cleanup| {
                self.secrets
                    .cloudflare_token(&cleanup.credential_id)
                    .map(|token| (cleanup.credential_id.clone(), token))
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
            for cleanup in attempted {
                let result = match cleanup.provider.as_str() {
                    "cloudflare" => match tokens.get(&cleanup.credential_id) {
                        Some(token) => acme.retry_cleanup(&cleanup, token.as_str()).await,
                        None => Err(format!(
                            "Cloudflare credential {} is unavailable for DNS cleanup {}",
                            cleanup.credential_id, cleanup.record_name
                        )),
                    },
                    provider => Err(format!("unsupported DNS cleanup provider {provider}")),
                };
                if let Err(error) = result {
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

    fn handle_acme_event(&mut self, event: AcmeEvent) {
        let mut status_error = None;
        match event {
            AcmeEvent::JobFinished(output) => {
                self.in_flight_certificates.remove(&output.certificate_id);
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

                match output.result {
                    Ok(material) if material.metadata.domains == certificate.domains => {
                        self.certificates
                            .install(output.certificate_id.clone(), material.clone());
                        self.retry_attempts.remove(&output.certificate_id);
                        if let Some(status) =
                            self.certificate_status.get_mut(&output.certificate_id)
                        {
                            status.state = CertificateState::Active;
                            status.not_before = Some(material.metadata.not_before_rfc3339.clone());
                            status.not_after = Some(material.metadata.not_after_rfc3339.clone());
                            status.last_error = None;
                        }
                        let renewal_at = fallback_renewal_time(
                            material.metadata.not_before,
                            material.metadata.not_after,
                        );
                        self.set_renewal_time(&output.certificate_id, renewal_at);
                        self.request_ari(&output.certificate_id, material);
                    }
                    Ok(_) => {
                        self.renewal_at
                            .insert(output.certificate_id.clone(), OffsetDateTime::now_utc());
                        self.queued_certificates
                            .insert(output.certificate_id.clone());
                        if let Some(status) =
                            self.certificate_status.get_mut(&output.certificate_id)
                        {
                            status.state =
                                if self.certificates.get(&output.certificate_id).is_some() {
                                    CertificateState::Degraded
                                } else {
                                    CertificateState::Pending
                                };
                            status.last_error = Some(
                                "discarded an ACME certificate issued for a stale configuration"
                                    .to_string(),
                            );
                        }
                    }
                    Err(error) => {
                        self.record_issuance_failure(&output.certificate_id, error);
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

    fn record_issuance_failure(&mut self, certificate_id: &str, error: String) {
        let attempt = self
            .retry_attempts
            .entry(certificate_id.to_string())
            .and_modify(|attempt| *attempt = attempt.saturating_add(1))
            .or_insert(1);
        let retry_at = OffsetDateTime::now_utc()
            + time::Duration::try_from(retry_delay(*attempt)).unwrap_or(time::Duration::hours(6));
        self.set_renewal_time(certificate_id, retry_at);
        if let Some(status) = self.certificate_status.get_mut(certificate_id) {
            status.state = if self.certificates.get(certificate_id).is_some() {
                CertificateState::Degraded
            } else {
                CertificateState::Failed
            };
            status.last_error = Some(error);
        }
    }

    fn set_renewal_time(&mut self, certificate_id: &str, renewal_at: OffsetDateTime) {
        self.renewal_at
            .insert(certificate_id.to_string(), renewal_at);
        self.update_next_renewal_status(certificate_id, renewal_at);
    }

    fn update_next_renewal_status(&mut self, certificate_id: &str, renewal_at: OffsetDateTime) {
        if let Some(status) = self.certificate_status.get_mut(certificate_id) {
            status.next_renewal_at = Some(format_timestamp(renewal_at));
        }
    }

    fn merge_pending_cleanups(&mut self, cleanups: Vec<PendingDnsCleanup>) {
        for cleanup in cleanups {
            if !self.pending_cleanups.contains(&cleanup) {
                self.pending_cleanups.push(cleanup);
            }
        }
    }

    fn persist_cleanup_journal(&self) -> Result<(), String> {
        self.storage.store_cleanup_journal(&self.pending_cleanups)
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
        if self.config.source.acme.directory != config.source.acme.directory {
            return Err("ACME directory changes require gateway stop/start".to_string());
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
                if !self.in_flight_certificates.contains(certificate_id) {
                    self.queued_certificates.insert(certificate_id.to_string());
                }
            }
            None => {
                for certificate_id in self.config.certificates.keys() {
                    if !self.in_flight_certificates.contains(certificate_id) {
                        self.queued_certificates.insert(certificate_id.clone());
                    }
                }
            }
        }
        self.drain_certificate_queue();
        self.publish_status(GatewayState::Running, None);
        Ok(())
    }

    async fn stop_listeners(&mut self) -> Result<(), String> {
        let _ = self.shutdown.send(true);
        self.proxy.cleanup().await;
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
        let mut certificates = self
            .certificate_status
            .values()
            .cloned()
            .collect::<Vec<_>>();
        certificates.sort_by(|left, right| left.id.cmp(&right.id));
        let last_error = last_error.or_else(|| self.certificates.callback_error());
        self.status.store(Arc::new(GatewayStatusSnapshot {
            schema_version: GATEWAY_SCHEMA_VERSION,
            state,
            config_generation: self.config_generation,
            listeners: self.listener_status.clone(),
            routes: self.routes.statuses(),
            certificates,
            pending_dns_cleanups: self.pending_cleanups.len(),
            last_error,
        }));
    }
}

fn fallback_renewal_time(not_before: OffsetDateTime, not_after: OffsetDateTime) -> OffsetDateTime {
    let maximum_jitter_seconds = time::Duration::hours(12).whole_seconds();
    let jitter_seconds = rand::random_range(0..=maximum_jitter_seconds);
    fallback_renewal_time_with_jitter(not_before, not_after, jitter_seconds)
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
                    Ok((stream, _)) => {
                        let _ = stream.set_nodelay(true);
                        let proxy = proxy.clone();
                        let shutdown = shutdown.clone();
                        let acceptor = acceptor.clone();
                        let callbacks = callbacks.clone();
                        connections.spawn(async move {
                            process_connection(stream, proxy, acceptor, callbacks, shutdown).await;
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
    proxy: Arc<HttpProxy<GatewayProxy>>,
    acceptor: Option<Arc<pingora::tls::ssl::SslAcceptor>>,
    callbacks: Option<Arc<pingora::listeners::TlsAcceptCallbacks>>,
    shutdown: watch::Receiver<bool>,
) {
    let l4_stream: l4::stream::Stream = stream.into();
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
    fn gateway_routes_tls_and_enforces_http_policy() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let temp = tempfile::tempdir().unwrap();
            let storage_dir = temp.path().join("gateway");
            let domains = ["app.gateway.test", "other.gateway.test"];
            let (certificate_pem, private_key_pem, certificate_der) = test_certificate(&domains);
            GatewayStorage::initialize(storage_dir.clone())
                .unwrap()
                .store_certificate(
                    "gateway-cert",
                    &domains
                        .iter()
                        .map(|domain| domain.to_string())
                        .collect::<Vec<_>>(),
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
            assert_eq!(status["certificates"][0]["state"], "active");
            let http_addr = status["listeners"]["http"].as_str().unwrap();
            let https_addr = status["listeners"]["https"].as_str().unwrap();

            let redirect = plain_http_request(http_addr, domains[0], "/hello?q=1").await;
            assert!(redirect.starts_with("HTTP/1.1 308"));
            assert!(
                redirect
                    .to_ascii_lowercase()
                    .contains("location: https://app.gateway.test/hello?q=1")
            );

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
            assert!(response.starts_with("HTTP/1.1 503"));
            assert!(response.to_ascii_lowercase().contains("retry-after: 30"));

            let unknown = plain_http_request(http_addr, "unknown.gateway.test", "/").await;
            assert!(unknown.starts_with("HTTP/1.1 421"));
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
            GatewayStorage::initialize(storage_dir.clone())
                .unwrap()
                .store_certificate(
                    "gateway-cert",
                    &[domain.to_string()],
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
            "schema_version": 1,
            "storage_dir": storage_dir,
            "listeners": {
                "http": http_listener,
                "https": https_listener
            },
            "acme": {
                "directory": { "kind": "letsencrypt_staging" },
                "contact_email": null,
                "terms_of_service_agreed": true
            },
            "certificates": [{
                "id": "gateway-cert",
                "domains": domains,
                "challenge": { "type": "http01" }
            }],
            "routes": domains.iter().map(|domain| json!({
                "domain": domain,
                "certificate_id": "gateway-cert",
                "upstream": {
                    "url": format!("http://{upstream_addr}"),
                    "host_header": null,
                    "tls_server_name": null
                }
            })).collect::<Vec<_>>()
        })
    }

    fn empty_secrets() -> Value {
        json!({ "schema_version": 1, "cloudflare": {} })
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
