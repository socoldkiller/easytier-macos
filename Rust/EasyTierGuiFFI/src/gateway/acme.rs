use std::{collections::BTreeSet, net::SocketAddr, sync::Arc, time::Duration};

use async_trait::async_trait;
use cloudflare::{
    endpoints::{
        dns::dns::{CreateDnsRecord, CreateDnsRecordParams, DeleteDnsRecord, DnsContent},
        zones::zone::{ListZones, ListZonesParams, Status},
    },
    framework::{
        Environment, SearchMatch,
        auth::Credentials,
        client::{ClientConfig, async_api::Client as CloudflareClient},
        response::ApiFailure,
    },
};
use hickory_resolver::{
    TokioResolver,
    config::{NameServerConfig, ResolverConfig},
    name_server::TokioConnectionProvider,
    proto::xfer::Protocol,
};
#[cfg(test)]
use instant_acme::HttpClient;
use instant_acme::{
    Account, AccountBuilder, AuthorizationStatus, CertificateIdentifier, ChallengeType, Identifier,
    NewAccount, NewOrder, OrderStatus, RetryPolicy,
};
use rustls_pki_types::CertificateDer;
use time::OffsetDateTime;
#[cfg(test)]
use tokio::sync::Mutex;
use tokio::{
    sync::{OnceCell, RwLock, watch},
    time::sleep,
};
use zeroize::Zeroizing;

use super::{
    config::{AcmeConfig, ChallengeConfig, ValidatedCertificate, normalize_domain},
    proxy::Http01ChallengeStore,
    storage::{GatewayStorage, PendingDnsCleanup},
    tls::CertifiedMaterial,
};

const DNS_PROPAGATION_TIMEOUT: Duration = Duration::from_secs(120);
const DNS_PROPAGATION_INTERVAL: Duration = Duration::from_secs(2);
const ACME_POLL_TIMEOUT: Duration = Duration::from_secs(120);

pub struct AcmeContext {
    config: RwLock<AcmeConfig>,
    storage: GatewayStorage,
    account: Arc<OnceCell<Account>>,
    challenges: Arc<Http01ChallengeStore>,
    dns_provider: Arc<dyn Dns01Provider>,
    #[cfg(test)]
    test_http: Mutex<Option<Box<dyn HttpClient>>>,
}

pub struct AcmeJobOutput {
    pub certificate_id: String,
    pub result: Result<Arc<CertifiedMaterial>, String>,
    pub cleanup_failures: Vec<PendingDnsCleanup>,
    pub cleanup_journal_error: Option<String>,
}

enum ProvisionedChallenge {
    Http01 { domain: String, token: String },
    Dns01 { cleanup: PendingDnsCleanup },
}

#[async_trait]
trait Dns01Provider: Send + Sync {
    async fn present(
        &self,
        api_token: &str,
        credential_id: &str,
        domain: &str,
        value: &str,
    ) -> Result<PendingDnsCleanup, Dns01PresentError>;

    async fn cleanup(&self, api_token: &str, cleanup: &PendingDnsCleanup) -> Result<(), String>;
}

struct Dns01PresentError {
    message: String,
    cleanup: Option<PendingDnsCleanup>,
}

struct CloudflareDnsProvider;

#[async_trait]
impl Dns01Provider for CloudflareDnsProvider {
    async fn present(
        &self,
        api_token: &str,
        credential_id: &str,
        domain: &str,
        value: &str,
    ) -> Result<PendingDnsCleanup, Dns01PresentError> {
        let (cleanup, name_servers) =
            create_cloudflare_dns01(api_token, credential_id, domain, value)
                .await
                .map_err(|message| Dns01PresentError {
                    message,
                    cleanup: None,
                })?;
        if let Err(message) =
            wait_for_authoritative_txt(&name_servers, &cleanup.record_name, value).await
        {
            return Err(Dns01PresentError {
                message,
                cleanup: Some(cleanup),
            });
        }
        Ok(cleanup)
    }

    async fn cleanup(&self, api_token: &str, cleanup: &PendingDnsCleanup) -> Result<(), String> {
        delete_cloudflare_record(api_token, &cleanup.zone_id, &cleanup.record_id).await
    }
}

#[derive(Clone, Debug)]
struct CloudflareZone {
    id: String,
    name_servers: Vec<String>,
}

impl AcmeContext {
    pub fn new(
        config: AcmeConfig,
        storage: GatewayStorage,
        challenges: Arc<Http01ChallengeStore>,
    ) -> Arc<Self> {
        Arc::new(Self {
            config: RwLock::new(config),
            storage,
            account: Arc::new(OnceCell::new()),
            challenges,
            dns_provider: Arc::new(CloudflareDnsProvider),
            #[cfg(test)]
            test_http: Mutex::new(None),
        })
    }

    #[cfg(test)]
    fn new_with_http(
        config: AcmeConfig,
        storage: GatewayStorage,
        challenges: Arc<Http01ChallengeStore>,
        http: Box<dyn HttpClient>,
    ) -> Arc<Self> {
        Arc::new(Self {
            config: RwLock::new(config),
            storage,
            account: Arc::new(OnceCell::new()),
            challenges,
            dns_provider: Arc::new(CloudflareDnsProvider),
            test_http: Mutex::new(Some(http)),
        })
    }

    #[cfg(test)]
    fn new_with_http_and_dns_provider(
        config: AcmeConfig,
        storage: GatewayStorage,
        challenges: Arc<Http01ChallengeStore>,
        http: Box<dyn HttpClient>,
        dns_provider: Arc<dyn Dns01Provider>,
    ) -> Arc<Self> {
        Arc::new(Self {
            config: RwLock::new(config),
            storage,
            account: Arc::new(OnceCell::new()),
            challenges,
            dns_provider,
            test_http: Mutex::new(Some(http)),
        })
    }

    pub async fn issue(
        &self,
        certificate: ValidatedCertificate,
        cloudflare_token: Option<Zeroizing<String>>,
        current_leaf_der: Option<Vec<u8>>,
        mut cancellation: watch::Receiver<bool>,
    ) -> AcmeJobOutput {
        let certificate_id = certificate.id.clone();
        let mut provisioned = Vec::new();
        let cloudflare_token_ref = cloudflare_token.as_ref().map(|token| token.as_str());
        let issue = self.issue_inner(
            &certificate,
            cloudflare_token_ref,
            current_leaf_der.as_deref(),
            &mut provisioned,
        );
        let result = tokio::select! {
            result = issue => result,
            changed = cancellation.changed() => {
                match changed {
                    Ok(()) if *cancellation.borrow() => Err("ACME operation was cancelled".to_string()),
                    Ok(()) | Err(_) => Err("ACME cancellation channel closed".to_string()),
                }
            }
        };
        let cleanup_failures = self
            .cleanup_challenges(provisioned, cloudflare_token_ref)
            .await;
        let cleanup_journal_error = if cleanup_failures.is_empty() {
            None
        } else {
            self.storage.merge_cleanup_journal(&cleanup_failures).err()
        };
        AcmeJobOutput {
            certificate_id,
            result,
            cleanup_failures,
            cleanup_journal_error,
        }
    }

    pub async fn suggested_renewal_time(
        &self,
        material: &CertifiedMaterial,
    ) -> Result<Option<(OffsetDateTime, Duration)>, String> {
        let account = self.account().await?;
        let certificate_der = CertificateDer::from(material.metadata.leaf_der.clone());
        let identifier = CertificateIdentifier::try_from(&certificate_der)
            .map_err(|error| format!("failed to derive ARI certificate identifier: {error}"))?;
        match account.renewal_info(&identifier).await {
            Ok((renewal, retry_after)) => {
                let start = renewal.suggested_window.start;
                let end = renewal.suggested_window.end;
                if end <= start {
                    return Err("ACME ARI returned an invalid renewal window".to_string());
                }
                let span = (end - start).whole_seconds();
                let offset = if span <= 1 {
                    0
                } else {
                    rand::random_range(0..span)
                };
                Ok(Some((start + time::Duration::seconds(offset), retry_after)))
            }
            Err(instant_acme::Error::Unsupported(_)) => Ok(None),
            Err(error) => Err(format!("failed to fetch ACME renewal information: {error}")),
        }
    }

    pub async fn update_config(&self, config: AcmeConfig) -> Result<(), String> {
        if let Some(account) = self.account.get() {
            let contact = config
                .contact_email
                .as_deref()
                .map(|email| format!("mailto:{email}"));
            let contacts = contact
                .as_deref()
                .map(|contact| vec![contact])
                .unwrap_or_default();
            account
                .update_contacts(&contacts)
                .await
                .map_err(|error| format!("failed to update ACME account contact: {error}"))?;
        }
        *self.config.write().await = config;
        Ok(())
    }

    pub async fn retry_cleanup(
        &self,
        cleanup: &PendingDnsCleanup,
        cloudflare_token: &str,
    ) -> Result<(), String> {
        self.dns_provider.cleanup(cloudflare_token, cleanup).await
    }

    async fn issue_inner(
        &self,
        certificate: &ValidatedCertificate,
        cloudflare_token: Option<&str>,
        current_leaf_der: Option<&[u8]>,
        provisioned: &mut Vec<ProvisionedChallenge>,
    ) -> Result<Arc<CertifiedMaterial>, String> {
        let account = self.account().await?;
        let identifiers = certificate
            .domains
            .iter()
            .cloned()
            .map(Identifier::Dns)
            .collect::<Vec<_>>();
        let mut new_order = NewOrder::new(&identifiers);
        if let Some(leaf_der) = current_leaf_der {
            let certificate_der = CertificateDer::from(leaf_der.to_vec());
            if let Ok(identifier) = CertificateIdentifier::try_from(&certificate_der)
                && account.renewal_info(&identifier).await.is_ok()
            {
                new_order = new_order.replaces(identifier);
            }
        }

        let mut order = account
            .new_order(&new_order)
            .await
            .map_err(|error| format!("failed to create ACME order: {error}"))?;
        {
            let mut authorizations = order.authorizations();
            while let Some(authorization) = authorizations.next().await {
                let mut authorization = authorization
                    .map_err(|error| format!("failed to load ACME authorization: {error}"))?;
                match authorization.status {
                    AuthorizationStatus::Valid => continue,
                    AuthorizationStatus::Pending => {}
                    other => {
                        return Err(format!(
                            "ACME authorization entered unexpected state {other:?}"
                        ));
                    }
                }

                let challenge_type = match certificate.challenge {
                    ChallengeConfig::Http01 => ChallengeType::Http01,
                    ChallengeConfig::Dns01 { .. } => ChallengeType::Dns01,
                };
                let mut challenge = authorization
                    .challenge(challenge_type.clone())
                    .ok_or_else(|| format!("ACME server did not offer {challenge_type:?}"))?;
                let identifier = challenge.identifier().to_string();
                let key_authorization = challenge.key_authorization();
                match &certificate.challenge {
                    ChallengeConfig::Http01 => {
                        let domain = normalize_domain(&identifier)?;
                        let token = challenge.token.clone();
                        self.challenges.insert(
                            domain.clone(),
                            token.clone(),
                            key_authorization.as_str().to_string(),
                        );
                        provisioned.push(ProvisionedChallenge::Http01 { domain, token });
                    }
                    ChallengeConfig::Dns01 { credential_id, .. } => {
                        let token = cloudflare_token.ok_or_else(|| {
                            format!(
                                "Cloudflare credential {credential_id} is unavailable for certificate {}",
                                certificate.id
                            )
                        })?;
                        let domain = identifier.trim_start_matches("*.");
                        let dns_value = key_authorization.dns_value();
                        let cleanup = match self
                            .dns_provider
                            .present(token, credential_id, domain, &dns_value)
                            .await
                        {
                            Ok(cleanup) => cleanup,
                            Err(error) => {
                                if let Some(cleanup) = error.cleanup {
                                    provisioned.push(ProvisionedChallenge::Dns01 { cleanup });
                                }
                                return Err(error.message);
                            }
                        };
                        provisioned.push(ProvisionedChallenge::Dns01 {
                            cleanup: cleanup.clone(),
                        });
                    }
                }
                challenge
                    .set_ready()
                    .await
                    .map_err(|error| format!("failed to mark ACME challenge ready: {error}"))?;
            }
        }

        let retry = RetryPolicy::new().timeout(ACME_POLL_TIMEOUT);
        let status = order
            .poll_ready(&retry)
            .await
            .map_err(|error| format!("failed while waiting for ACME authorization: {error}"))?;
        if status != OrderStatus::Ready {
            return Err(format!("ACME order did not become ready: {status:?}"));
        }

        let private_key_pem = order
            .finalize()
            .await
            .map_err(|error| format!("failed to finalize ACME order: {error}"))?;
        let certificate_chain_pem = order
            .poll_certificate(&retry)
            .await
            .map_err(|error| format!("failed to retrieve ACME certificate: {error}"))?;
        self.storage.store_certificate(
            &certificate.id,
            &certificate.domains,
            &certificate_chain_pem,
            &private_key_pem,
        )
    }

    async fn cleanup_challenges(
        &self,
        provisioned: Vec<ProvisionedChallenge>,
        cloudflare_token: Option<&str>,
    ) -> Vec<PendingDnsCleanup> {
        let mut failures = Vec::new();
        for challenge in provisioned {
            match challenge {
                ProvisionedChallenge::Http01 { domain, token } => {
                    self.challenges.remove(&domain, &token);
                }
                ProvisionedChallenge::Dns01 { cleanup } => {
                    let result = match cloudflare_token {
                        Some(token) => self.dns_provider.cleanup(token, &cleanup).await,
                        None => {
                            Err("Cloudflare credential is unavailable during cleanup".to_string())
                        }
                    };
                    if result.is_err() {
                        failures.push(cleanup);
                    }
                }
            }
        }
        failures
    }

    async fn account(&self) -> Result<Account, String> {
        let config = self.config.read().await.clone();
        self.account
            .get_or_try_init(|| async {
                let directory_url = config.directory.url().to_string();
                let builder = self.account_builder(&config).await?;
                if let Some(credentials) = self.storage.load_account(&directory_url)? {
                    return builder
                        .from_credentials(credentials)
                        .await
                        .map_err(|error| format!("failed to restore ACME account: {error}"));
                }

                let contact = config
                    .contact_email
                    .as_deref()
                    .map(|email| format!("mailto:{email}"));
                let contact_refs = contact
                    .as_deref()
                    .map(|contact| vec![contact])
                    .unwrap_or_default();
                let (account, credentials) = builder
                    .create(
                        &NewAccount {
                            contact: &contact_refs,
                            terms_of_service_agreed: config.terms_of_service_agreed,
                            only_return_existing: false,
                        },
                        directory_url.clone(),
                        None,
                    )
                    .await
                    .map_err(|error| format!("failed to create ACME account: {error}"))?;
                self.storage.store_account(&directory_url, &credentials)?;
                Ok(account)
            })
            .await
            .cloned()
    }

    async fn account_builder(&self, config: &AcmeConfig) -> Result<AccountBuilder, String> {
        #[cfg(test)]
        if let Some(http) = self.test_http.lock().await.take() {
            return Ok(Account::builder_with_http(http));
        }

        match config.directory.custom_ca_cert_path() {
            Some(path) => Account::builder_with_root(path)
                .map_err(|error| format!("failed to configure custom ACME CA: {error}")),
            None => Account::builder()
                .map_err(|error| format!("failed to create ACME HTTP client: {error}")),
        }
    }
}

async fn create_cloudflare_dns01(
    api_token: &str,
    credential_id: &str,
    domain: &str,
    value: &str,
) -> Result<(PendingDnsCleanup, Vec<String>), String> {
    let client = cloudflare_client(api_token)?;
    create_cloudflare_dns01_with_client(&client, credential_id, domain, value).await
}

async fn create_cloudflare_dns01_with_client(
    client: &CloudflareClient,
    credential_id: &str,
    domain: &str,
    value: &str,
) -> Result<(PendingDnsCleanup, Vec<String>), String> {
    let zone = discover_cloudflare_zone(client, domain).await?;
    let record_name = format!("_acme-challenge.{domain}");
    let response = client
        .request(&CreateDnsRecord {
            zone_identifier: &zone.id,
            params: CreateDnsRecordParams {
                ttl: Some(1),
                priority: None,
                proxied: Some(false),
                name: &record_name,
                content: DnsContent::TXT {
                    content: value.to_string(),
                },
            },
        })
        .await
        .map_err(|error| format!("Cloudflare TXT creation failed: {error}"))?;
    let cleanup = PendingDnsCleanup {
        provider: "cloudflare".to_string(),
        credential_id: credential_id.to_string(),
        zone_id: zone.id,
        record_id: response.result.id,
        record_name: record_name.clone(),
    };

    Ok((cleanup, zone.name_servers))
}

async fn discover_cloudflare_zone(
    client: &CloudflareClient,
    domain: &str,
) -> Result<CloudflareZone, String> {
    let labels = domain.split('.').collect::<Vec<_>>();
    for index in 0..labels.len() {
        let candidate = labels[index..].join(".");
        let response = client
            .request(&ListZones {
                params: ListZonesParams {
                    name: Some(candidate),
                    status: Some(Status::Active),
                    search_match: Some(SearchMatch::All),
                    ..ListZonesParams::default()
                },
            })
            .await
            .map_err(|error| format!("Cloudflare zone discovery failed: {error}"))?;
        if let Some(zone) = response.result.into_iter().next() {
            if zone.name_servers.is_empty() {
                return Err(format!(
                    "Cloudflare zone {} did not provide authoritative nameservers",
                    zone.name
                ));
            }
            return Ok(CloudflareZone {
                id: zone.id,
                name_servers: zone.name_servers,
            });
        }
    }
    Err(format!("no active Cloudflare zone covers {domain}"))
}

async fn delete_cloudflare_record(
    api_token: &str,
    zone_id: &str,
    record_id: &str,
) -> Result<(), String> {
    let client = cloudflare_client(api_token)?;
    delete_cloudflare_record_with_client(&client, zone_id, record_id).await
}

async fn delete_cloudflare_record_with_client(
    client: &CloudflareClient,
    zone_id: &str,
    record_id: &str,
) -> Result<(), String> {
    client
        .request(&DeleteDnsRecord {
            zone_identifier: zone_id,
            identifier: record_id,
        })
        .await
        .map(|_| ())
        .or_else(|error| match &error {
            ApiFailure::Error(status, _) if status.as_u16() == 404 => Ok(()),
            _ => Err(error),
        })
        .map_err(|error| format!("Cloudflare TXT cleanup failed: {error}"))
}

fn cloudflare_client(api_token: &str) -> Result<CloudflareClient, String> {
    cloudflare_client_with_environment(api_token, Environment::Production)
}

fn cloudflare_client_with_environment(
    api_token: &str,
    environment: Environment,
) -> Result<CloudflareClient, String> {
    CloudflareClient::new(
        Credentials::UserAuthToken {
            token: api_token.to_string(),
        },
        ClientConfig {
            http_timeout: Duration::from_secs(30),
            ..ClientConfig::default()
        },
        environment,
    )
    .map_err(|error| format!("failed to create Cloudflare API client: {error}"))
}

async fn wait_for_authoritative_txt(
    name_servers: &[String],
    record_name: &str,
    expected: &str,
) -> Result<(), String> {
    let deadline = tokio::time::Instant::now() + DNS_PROPAGATION_TIMEOUT;
    loop {
        let mut all_visible = true;
        for name_server in name_servers {
            match authoritative_txt_values(name_server, record_name).await {
                Ok(values) if values.contains(expected) => {}
                Ok(_) | Err(_) => {
                    all_visible = false;
                    break;
                }
            }
        }
        if all_visible {
            return Ok(());
        }
        if tokio::time::Instant::now() >= deadline {
            return Err(format!(
                "DNS-01 TXT record {record_name} did not propagate to all Cloudflare nameservers within {} seconds",
                DNS_PROPAGATION_TIMEOUT.as_secs()
            ));
        }
        sleep(DNS_PROPAGATION_INTERVAL).await;
    }
}

async fn authoritative_txt_values(
    name_server: &str,
    record_name: &str,
) -> Result<BTreeSet<String>, String> {
    let addresses = tokio::net::lookup_host(format!("{name_server}:53"))
        .await
        .map_err(|error| format!("failed to resolve nameserver {name_server}: {error}"))?
        .collect::<Vec<SocketAddr>>();
    if addresses.is_empty() {
        return Err(format!(
            "nameserver {name_server} did not resolve to an address"
        ));
    }

    let mut last_error = None;
    for address in addresses {
        match authoritative_txt_values_at(address, record_name).await {
            Ok(values) => return Ok(values),
            Err(error) => last_error = Some(error),
        }
    }
    Err(last_error.unwrap_or_else(|| {
        format!("TXT lookup via {name_server} did not use any resolved address")
    }))
}

async fn authoritative_txt_values_at(
    address: SocketAddr,
    record_name: &str,
) -> Result<BTreeSet<String>, String> {
    let config = ResolverConfig::from_parts(
        None,
        Vec::new(),
        vec![NameServerConfig::new(address, Protocol::Udp)],
    );
    let mut builder =
        TokioResolver::builder_with_config(config, TokioConnectionProvider::default());
    builder.options_mut().attempts = 1;
    builder.options_mut().timeout = Duration::from_secs(2);
    builder.options_mut().cache_size = 0;
    let resolver = builder.build();
    let lookup = resolver
        .txt_lookup(record_name)
        .await
        .map_err(|error| format!("TXT lookup via {address} failed: {error}"))?;
    Ok(lookup
        .iter()
        .map(|txt| {
            txt.txt_data()
                .iter()
                .flat_map(|part| part.iter().copied())
                .collect::<Vec<_>>()
        })
        .filter_map(|value| String::from_utf8(value).ok())
        .collect())
}

#[cfg(test)]
mod tests {
    use std::{
        future::Future,
        pin::Pin,
        sync::{Arc, Mutex as StdMutex},
    };

    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use bytes::Bytes;
    use http::{Request, Response, StatusCode};
    use http_body_util::BodyExt as _;
    use instant_acme::{BodyWrapper, BytesResponse, Error as AcmeError};
    use rcgen::{
        BasicConstraints, CertificateParams, CertificateSigningRequestParams, IsCa, Issuer, KeyPair,
    };
    use rustls_pki_types::CertificateSigningRequestDer;
    use serde_json::{Value, json};
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
        sync::{Mutex as TokioMutex, oneshot},
    };

    use super::*;
    use crate::gateway::config::{AcmeDirectoryConfig, DnsProviderKind};

    #[test]
    fn dns01_record_name_removes_wildcard_prefix() {
        let domain = "*.example.com".trim_start_matches("*.");
        assert_eq!(
            format!("_acme-challenge.{domain}"),
            "_acme-challenge.example.com"
        );
    }

    #[test]
    fn cloudflare_dns01_discovers_zone_and_manages_txt_record() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let requests = Arc::new(TokioMutex::new(Vec::new()));
            let server_requests = requests.clone();
            let (finished_sender, finished_receiver) = oneshot::channel();
            tokio::spawn(async move {
                for _ in 0..5 {
                    let (mut stream, _) = listener.accept().await.unwrap();
                    let request = read_http_request(&mut stream).await;
                    let first_line = request.lines().next().unwrap_or_default();
                    let response = if first_line.starts_with("GET ")
                        && request.contains("name=app.example.com")
                    {
                        cloudflare_response(json!([]), 200)
                    } else if first_line.starts_with("GET ") && request.contains("name=example.com")
                    {
                        cloudflare_response(json!([cloudflare_zone()]), 200)
                    } else if first_line.starts_with("POST /client/v4/zones/zone-id/dns_records ") {
                        cloudflare_response(
                            json!({
                                "meta": {},
                                "name": "_acme-challenge.app.example.com",
                                "ttl": 1,
                                "modified_on": "2026-01-01T00:00:00Z",
                                "created_on": "2026-01-01T00:00:00Z",
                                "proxiable": false,
                                "type": "TXT",
                                "content": "dns-proof",
                                "id": "record-id",
                                "proxied": false
                            }),
                            200,
                        )
                    } else if first_line
                        .starts_with("DELETE /client/v4/zones/zone-id/dns_records/record-id ")
                        && server_requests.lock().await.len() < 4
                    {
                        cloudflare_response(json!({ "id": "record-id" }), 200)
                    } else {
                        cloudflare_response(json!(null), 404)
                    };
                    server_requests.lock().await.push(request);
                    stream.write_all(response.as_bytes()).await.unwrap();
                }
                let _ = finished_sender.send(());
            });

            let client = cloudflare_client_with_environment(
                "test-token",
                Environment::Custom(format!("http://{address}/client/v4/")),
            )
            .unwrap();
            let (cleanup, name_servers) = create_cloudflare_dns01_with_client(
                &client,
                "cf-main",
                "app.example.com",
                "dns-proof",
            )
            .await
            .unwrap();
            assert_eq!(cleanup.credential_id, "cf-main");
            assert_eq!(cleanup.zone_id, "zone-id");
            assert_eq!(cleanup.record_id, "record-id");
            assert_eq!(cleanup.record_name, "_acme-challenge.app.example.com");
            assert_eq!(name_servers, ["ns1.example.test", "ns2.example.test"]);

            delete_cloudflare_record_with_client(&client, "zone-id", "record-id")
                .await
                .unwrap();
            delete_cloudflare_record_with_client(&client, "zone-id", "record-id")
                .await
                .unwrap();
            finished_receiver.await.unwrap();

            let requests = requests.lock().await;
            assert_eq!(requests.len(), 5);
            assert!(requests.iter().all(|request| {
                request
                    .to_ascii_lowercase()
                    .contains("authorization: bearer test-token")
            }));
            let create = &requests[2];
            let body = create.split("\r\n\r\n").nth(1).unwrap();
            let body: Value = serde_json::from_str(body).unwrap();
            assert_eq!(body["type"], "TXT");
            assert_eq!(body["content"], "dns-proof");
            assert_eq!(body["name"], "_acme-challenge.app.example.com");
            assert_eq!(body["ttl"], 1);
            assert_eq!(body["proxied"], false);
        });
    }

    #[test]
    fn instant_acme_http01_flow_issues_and_persists_certificate() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let temp = tempfile::tempdir().unwrap();
            let storage = GatewayStorage::initialize(temp.path().join("gateway")).unwrap();
            let challenges = Http01ChallengeStore::new();
            let mock = MockAcmeClient::new(challenges.clone());
            let mock_state = mock.state.clone();
            let context = AcmeContext::new_with_http(
                AcmeConfig {
                    directory: AcmeDirectoryConfig::LetsencryptStaging,
                    contact_email: Some("ops@example.com".to_string()),
                    terms_of_service_agreed: true,
                },
                storage.clone(),
                challenges.clone(),
                Box::new(mock),
            );
            let certificate = ValidatedCertificate {
                id: "http01-cert".to_string(),
                domains: vec!["app.acme.test".to_string()],
                challenge: ChallengeConfig::Http01,
            };
            let (_shutdown_sender, shutdown) = watch::channel(false);

            let output = context
                .issue(certificate.clone(), None, None, shutdown)
                .await;
            let material = output.result.unwrap();
            assert_eq!(material.metadata.domains, ["app.acme.test"]);
            assert!(output.cleanup_failures.is_empty());
            assert!(output.cleanup_journal_error.is_none());
            assert!(challenges.get("app.acme.test", "http01-token").is_none());
            assert!(
                storage
                    .load_certificate("http01-cert", &["app.acme.test".to_string()])
                    .unwrap()
                    .is_some()
            );
            assert_eq!(
                std::fs::read_dir(temp.path().join("gateway/accounts"))
                    .unwrap()
                    .count(),
                1
            );

            let (renewal_at, retry_after) = context
                .suggested_renewal_time(&material)
                .await
                .unwrap()
                .unwrap();
            let now = OffsetDateTime::now_utc();
            assert!(renewal_at > now + time::Duration::days(9));
            assert!(renewal_at < now + time::Duration::days(21));
            assert!(retry_after >= Duration::from_secs(3_500));
            assert!(retry_after <= Duration::from_secs(3_600));

            let first_leaf = material.metadata.leaf_der.clone();
            let (_renewal_shutdown_sender, renewal_shutdown) = watch::channel(false);
            let renewal = context
                .issue(
                    certificate,
                    None,
                    Some(first_leaf.clone()),
                    renewal_shutdown,
                )
                .await
                .result
                .unwrap();
            assert_ne!(renewal.metadata.leaf_der, first_leaf);

            let state = mock_state.lock().unwrap();
            assert!(state.challenge_was_provisioned);
            assert!(state.certificate_pem.is_some());
            assert!(state.replaces.is_some());
            assert_eq!(
                state
                    .requests
                    .iter()
                    .filter(|request| request.ends_with("/new-account"))
                    .count(),
                1
            );
            assert_eq!(
                state
                    .requests
                    .iter()
                    .filter(|request| request.ends_with("/new-order"))
                    .count(),
                2
            );
            for endpoint in [
                "/directory",
                "/new-nonce",
                "/new-account",
                "/new-order",
                "/authz/1",
                "/challenge/1",
                "/finalize/1",
                "/certificate/1",
            ] {
                assert!(
                    state
                        .requests
                        .iter()
                        .any(|request| request.ends_with(endpoint))
                );
            }
        });
    }

    #[test]
    fn instant_acme_dns01_flow_presents_and_cleans_txt_record() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let temp = tempfile::tempdir().unwrap();
            let storage = GatewayStorage::initialize(temp.path().join("gateway")).unwrap();
            let challenges = Http01ChallengeStore::new();
            let mock_acme = MockAcmeClient::new_wildcard(challenges.clone());
            let mock_acme_state = mock_acme.state.clone();
            let mock_dns = Arc::new(MockDnsProvider::default());
            let context = AcmeContext::new_with_http_and_dns_provider(
                AcmeConfig {
                    directory: AcmeDirectoryConfig::LetsencryptStaging,
                    contact_email: None,
                    terms_of_service_agreed: true,
                },
                storage.clone(),
                challenges,
                Box::new(mock_acme),
                mock_dns.clone(),
            );
            let certificate = ValidatedCertificate {
                id: "dns01-cert".to_string(),
                domains: vec!["*.acme.test".to_string()],
                challenge: ChallengeConfig::Dns01 {
                    provider: DnsProviderKind::Cloudflare,
                    credential_id: "cf-main".to_string(),
                },
            };
            let (_shutdown_sender, shutdown) = watch::channel(false);

            let output = context
                .issue(
                    certificate,
                    Some(Zeroizing::new("cloudflare-token".to_string())),
                    None,
                    shutdown,
                )
                .await;
            assert!(output.result.is_ok());
            assert!(output.cleanup_failures.is_empty());
            assert!(
                storage
                    .load_certificate("dns01-cert", &["*.acme.test".to_string()])
                    .unwrap()
                    .is_some()
            );

            let dns = mock_dns.state.lock().unwrap();
            assert_eq!(dns.presented.len(), 1);
            let presented = &dns.presented[0];
            assert_eq!(presented.api_token, "cloudflare-token");
            assert_eq!(presented.credential_id, "cf-main");
            assert_eq!(presented.domain, "acme.test");
            assert!(!presented.value.is_empty());
            assert!(
                presented
                    .value
                    .bytes()
                    .all(|byte| { byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_') })
            );
            assert_eq!(dns.cleaned.len(), 1);
            assert_eq!(dns.cleaned[0].record_id, "mock-record");
            drop(dns);

            let acme = mock_acme_state.lock().unwrap();
            assert!(acme.challenge_ready);
            assert!(
                acme.requests
                    .iter()
                    .any(|request| request.ends_with("/challenge/dns"))
            );
        });
    }

    #[test]
    fn dns01_propagation_failure_persists_failed_cleanup() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let temp = tempfile::tempdir().unwrap();
            let storage = GatewayStorage::initialize(temp.path().join("gateway")).unwrap();
            let challenges = Http01ChallengeStore::new();
            let mock_acme = MockAcmeClient::new(challenges.clone());
            let cleanup_attempted = Arc::new(StdMutex::new(false));
            let context = AcmeContext::new_with_http_and_dns_provider(
                AcmeConfig {
                    directory: AcmeDirectoryConfig::LetsencryptStaging,
                    contact_email: None,
                    terms_of_service_agreed: true,
                },
                storage.clone(),
                challenges,
                Box::new(mock_acme),
                Arc::new(FailingDnsProvider {
                    cleanup_attempted: cleanup_attempted.clone(),
                }),
            );
            let certificate = ValidatedCertificate {
                id: "failed-dns01-cert".to_string(),
                domains: vec!["app.acme.test".to_string()],
                challenge: ChallengeConfig::Dns01 {
                    provider: DnsProviderKind::Cloudflare,
                    credential_id: "cf-main".to_string(),
                },
            };
            let (_shutdown_sender, shutdown) = watch::channel(false);

            let output = context
                .issue(
                    certificate,
                    Some(Zeroizing::new("cloudflare-token".to_string())),
                    None,
                    shutdown,
                )
                .await;
            assert!(output.result.unwrap_err().contains("did not propagate"));
            assert_eq!(output.cleanup_failures.len(), 1);
            assert!(*cleanup_attempted.lock().unwrap());
            let journal = storage.load_cleanup_journal().unwrap();
            assert_eq!(journal, output.cleanup_failures);
            assert_eq!(journal[0].record_id, "orphan-record");
        });
    }

    #[derive(Clone)]
    struct MockAcmeClient {
        state: Arc<StdMutex<MockAcmeState>>,
        challenges: Arc<Http01ChallengeStore>,
        identifier: String,
        wildcard: bool,
    }

    #[derive(Default)]
    struct MockAcmeState {
        requests: Vec<String>,
        challenge_was_provisioned: bool,
        challenge_ready: bool,
        certificate_pem: Option<String>,
        replaces: Option<String>,
    }

    impl MockAcmeClient {
        fn new(challenges: Arc<Http01ChallengeStore>) -> Self {
            Self {
                state: Arc::new(StdMutex::new(MockAcmeState::default())),
                challenges,
                identifier: "app.acme.test".to_string(),
                wildcard: false,
            }
        }

        fn new_wildcard(challenges: Arc<Http01ChallengeStore>) -> Self {
            Self {
                state: Arc::new(StdMutex::new(MockAcmeState::default())),
                challenges,
                identifier: "acme.test".to_string(),
                wildcard: true,
            }
        }

        async fn handle(
            self,
            request: Request<BodyWrapper<Bytes>>,
        ) -> Result<BytesResponse, AcmeError> {
            let method = request.method().clone();
            let path = request.uri().path().to_string();
            let body = request
                .into_body()
                .collect()
                .await
                .expect("ACME request body is infallible")
                .to_bytes();
            self.state
                .lock()
                .unwrap()
                .requests
                .push(format!("{method} {path}"));

            match (method.as_str(), path.as_str()) {
                ("GET", "/directory") => Ok(acme_json_response(
                    StatusCode::OK,
                    json!({
                        "newNonce": "https://acme.test/new-nonce",
                        "newAccount": "https://acme.test/new-account",
                        "newOrder": "https://acme.test/new-order",
                        "renewalInfo": "https://acme.test/renewal-info"
                    }),
                    None,
                )),
                ("HEAD", "/new-nonce") => Ok(acme_raw_response(
                    StatusCode::OK,
                    Vec::new(),
                    None,
                    "application/json",
                )),
                ("POST", "/new-account") => Ok(acme_json_response(
                    StatusCode::CREATED,
                    json!({}),
                    Some("https://acme.test/account/1"),
                )),
                ("POST", "/new-order") => {
                    let payload = decode_jose_payload(&body);
                    let replaces = payload
                        .get("replaces")
                        .and_then(Value::as_str)
                        .map(str::to_string);
                    let mut state = self.state.lock().unwrap();
                    state.challenge_ready = false;
                    state.certificate_pem = None;
                    state.replaces = replaces.clone();
                    Ok(acme_json_response(
                        StatusCode::CREATED,
                        acme_order_state("pending", None, replaces.as_deref()),
                        Some("https://acme.test/order/1"),
                    ))
                }
                ("POST", "/authz/1") => Ok(acme_json_response(
                    StatusCode::OK,
                    json!({
                        "identifier": { "type": "dns", "value": self.identifier },
                        "status": "pending",
                        "challenges": [{
                            "type": "http-01",
                            "url": "https://acme.test/challenge/1",
                            "token": "http01-token",
                            "status": "pending"
                        }, {
                            "type": "dns-01",
                            "url": "https://acme.test/challenge/dns",
                            "token": "dns01-token",
                            "status": "pending"
                        }],
                        "wildcard": self.wildcard
                    }),
                    None,
                )),
                ("POST", "/challenge/1") => {
                    let provisioned = self
                        .challenges
                        .get(&self.identifier, "http01-token")
                        .is_some_and(|value| value.starts_with("http01-token."));
                    let mut state = self.state.lock().unwrap();
                    state.challenge_was_provisioned = provisioned;
                    state.challenge_ready = true;
                    Ok(acme_json_response(
                        StatusCode::OK,
                        json!({
                            "type": "http-01",
                            "url": "https://acme.test/challenge/1",
                            "token": "http01-token",
                            "status": "valid"
                        }),
                        None,
                    ))
                }
                ("POST", "/challenge/dns") => {
                    self.state.lock().unwrap().challenge_ready = true;
                    Ok(acme_json_response(
                        StatusCode::OK,
                        json!({
                            "type": "dns-01",
                            "url": "https://acme.test/challenge/dns",
                            "token": "dns01-token",
                            "status": "valid"
                        }),
                        None,
                    ))
                }
                ("POST", "/order/1") => {
                    let state = self.state.lock().unwrap();
                    let (status, certificate) = if state.certificate_pem.is_some() {
                        ("valid", Some("https://acme.test/certificate/1"))
                    } else if state.challenge_ready {
                        ("ready", None)
                    } else {
                        ("pending", None)
                    };
                    Ok(acme_json_response(
                        StatusCode::OK,
                        acme_order_state(status, certificate, state.replaces.as_deref()),
                        None,
                    ))
                }
                ("POST", "/finalize/1") => {
                    let certificate_pem = sign_acme_csr(&body);
                    let mut state = self.state.lock().unwrap();
                    state.certificate_pem = Some(certificate_pem);
                    let replaces = state.replaces.clone();
                    Ok(acme_json_response(
                        StatusCode::OK,
                        acme_order_state("processing", None, replaces.as_deref()),
                        None,
                    ))
                }
                ("POST", "/certificate/1") => {
                    let certificate = self.state.lock().unwrap().certificate_pem.clone().unwrap();
                    Ok(acme_raw_response(
                        StatusCode::OK,
                        certificate.into_bytes(),
                        None,
                        "application/pem-certificate-chain",
                    ))
                }
                ("GET", path) if path.starts_with("/renewal-info/") => {
                    let start = (OffsetDateTime::now_utc() + time::Duration::days(10))
                        .format(&time::format_description::well_known::Rfc3339)
                        .unwrap();
                    let end = (OffsetDateTime::now_utc() + time::Duration::days(20))
                        .format(&time::format_description::well_known::Rfc3339)
                        .unwrap();
                    let mut response = acme_json_response(
                        StatusCode::OK,
                        json!({
                            "suggestedWindow": {
                                "start": start,
                                "end": end
                            }
                        }),
                        None,
                    );
                    response
                        .parts
                        .headers
                        .insert("Retry-After", http::HeaderValue::from_static("3600"));
                    Ok(response)
                }
                _ => panic!("unexpected ACME request: {method} {path}"),
            }
        }
    }

    impl HttpClient for MockAcmeClient {
        fn request(
            &self,
            request: Request<BodyWrapper<Bytes>>,
        ) -> Pin<Box<dyn Future<Output = Result<BytesResponse, AcmeError>> + Send>> {
            let client = self.clone();
            Box::pin(async move { client.handle(request).await })
        }
    }

    #[derive(Default)]
    struct MockDnsProvider {
        state: StdMutex<MockDnsState>,
    }

    #[derive(Default)]
    struct MockDnsState {
        presented: Vec<MockDnsPresentation>,
        cleaned: Vec<PendingDnsCleanup>,
    }

    struct MockDnsPresentation {
        api_token: String,
        credential_id: String,
        domain: String,
        value: String,
    }

    #[async_trait]
    impl Dns01Provider for MockDnsProvider {
        async fn present(
            &self,
            api_token: &str,
            credential_id: &str,
            domain: &str,
            value: &str,
        ) -> Result<PendingDnsCleanup, Dns01PresentError> {
            self.state
                .lock()
                .unwrap()
                .presented
                .push(MockDnsPresentation {
                    api_token: api_token.to_string(),
                    credential_id: credential_id.to_string(),
                    domain: domain.to_string(),
                    value: value.to_string(),
                });
            Ok(PendingDnsCleanup {
                provider: "cloudflare".to_string(),
                credential_id: credential_id.to_string(),
                zone_id: "mock-zone".to_string(),
                record_id: "mock-record".to_string(),
                record_name: format!("_acme-challenge.{domain}"),
            })
        }

        async fn cleanup(
            &self,
            _api_token: &str,
            cleanup: &PendingDnsCleanup,
        ) -> Result<(), String> {
            self.state.lock().unwrap().cleaned.push(cleanup.clone());
            Ok(())
        }
    }

    struct FailingDnsProvider {
        cleanup_attempted: Arc<StdMutex<bool>>,
    }

    #[async_trait]
    impl Dns01Provider for FailingDnsProvider {
        async fn present(
            &self,
            _api_token: &str,
            credential_id: &str,
            domain: &str,
            _value: &str,
        ) -> Result<PendingDnsCleanup, Dns01PresentError> {
            Err(Dns01PresentError {
                message: "DNS-01 TXT record did not propagate".to_string(),
                cleanup: Some(PendingDnsCleanup {
                    provider: "cloudflare".to_string(),
                    credential_id: credential_id.to_string(),
                    zone_id: "orphan-zone".to_string(),
                    record_id: "orphan-record".to_string(),
                    record_name: format!("_acme-challenge.{domain}"),
                }),
            })
        }

        async fn cleanup(
            &self,
            _api_token: &str,
            _cleanup: &PendingDnsCleanup,
        ) -> Result<(), String> {
            *self.cleanup_attempted.lock().unwrap() = true;
            Err("simulated Cloudflare cleanup failure".to_string())
        }
    }

    fn acme_order_state(status: &str, certificate: Option<&str>, replaces: Option<&str>) -> Value {
        json!({
            "status": status,
            "authorizations": ["https://acme.test/authz/1"],
            "finalize": "https://acme.test/finalize/1",
            "certificate": certificate,
            "replaces": replaces
        })
    }

    fn acme_json_response(
        status: StatusCode,
        body: Value,
        location: Option<&str>,
    ) -> BytesResponse {
        acme_raw_response(
            status,
            body.to_string().into_bytes(),
            location,
            "application/json",
        )
    }

    fn acme_raw_response(
        status: StatusCode,
        body: Vec<u8>,
        location: Option<&str>,
        content_type: &str,
    ) -> BytesResponse {
        let mut response = Response::builder()
            .status(status)
            .header("Replay-Nonce", "test-nonce")
            .header("Content-Type", content_type);
        if let Some(location) = location {
            response = response.header("Location", location);
        }
        BytesResponse::from(response.body(BodyWrapper::from(body)).unwrap())
    }

    fn sign_acme_csr(jose_body: &[u8]) -> String {
        let payload = decode_jose_payload(jose_body);
        let csr = URL_SAFE_NO_PAD
            .decode(payload["csr"].as_str().unwrap())
            .unwrap();
        let csr_der = CertificateSigningRequestDer::from(csr);
        let mut csr = CertificateSigningRequestParams::from_der(&csr_der).unwrap();
        csr.params.not_before = OffsetDateTime::now_utc() - time::Duration::days(1);
        csr.params.not_after = OffsetDateTime::now_utc() + time::Duration::days(90);
        csr.params.use_authority_key_identifier_extension = true;

        let mut issuer_params = CertificateParams::new(Vec::<String>::new()).unwrap();
        issuer_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        let issuer = Issuer::new(issuer_params, KeyPair::generate().unwrap());
        csr.signed_by(&issuer).unwrap().pem()
    }

    fn decode_jose_payload(jose_body: &[u8]) -> Value {
        let jose: Value = serde_json::from_slice(jose_body).unwrap();
        let payload = URL_SAFE_NO_PAD
            .decode(jose["payload"].as_str().unwrap())
            .unwrap();
        serde_json::from_slice(&payload).unwrap()
    }

    fn cloudflare_zone() -> Value {
        json!({
            "id": "zone-id",
            "name": "example.com",
            "account": { "id": "account-id", "name": "Example" },
            "activated_on": "2026-01-01T00:00:00Z",
            "created_on": "2026-01-01T00:00:00Z",
            "development_mode": 0,
            "meta": {
                "custom_certificate_quota": 0,
                "page_rule_quota": 0,
                "phishing_detected": false
            },
            "modified_on": "2026-01-01T00:00:00Z",
            "name_servers": ["ns1.example.test", "ns2.example.test"],
            "owner": { "type": "user", "id": null, "email": null },
            "paused": false,
            "permissions": ["#dns_records:edit"],
            "status": "active",
            "type": "full"
        })
    }

    fn cloudflare_response(result: Value, status: u16) -> String {
        let body = json!({
            "success": status < 400,
            "errors": [],
            "messages": [],
            "result": result,
            "result_info": null
        })
        .to_string();
        let reason = if status == 200 { "OK" } else { "Not Found" };
        format!(
            "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
    }

    async fn read_http_request(stream: &mut tokio::net::TcpStream) -> String {
        let mut request = Vec::new();
        let mut buffer = [0_u8; 2_048];
        let header_end;
        loop {
            let count = stream.read(&mut buffer).await.unwrap();
            assert!(count > 0);
            request.extend_from_slice(&buffer[..count]);
            if let Some(position) = request.windows(4).position(|window| window == b"\r\n\r\n") {
                header_end = position + 4;
                break;
            }
        }
        let headers = String::from_utf8_lossy(&request[..header_end]);
        let content_length = headers
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().ok())
                    .flatten()
            })
            .unwrap_or(0);
        while request.len() < header_end + content_length {
            let count = stream.read(&mut buffer).await.unwrap();
            assert!(count > 0);
            request.extend_from_slice(&buffer[..count]);
        }
        String::from_utf8(request).unwrap()
    }
}
