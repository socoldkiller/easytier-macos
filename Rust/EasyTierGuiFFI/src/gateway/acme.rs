use std::{collections::BTreeSet, net::SocketAddr, sync::Arc, time::Duration};

use async_trait::async_trait;
use base64::Engine as _;
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
use hmac::{Hmac, Mac};
#[cfg(test)]
use instant_acme::HttpClient;
use instant_acme::{
    Account, AuthorizationStatus, CertificateIdentifier, ChallengeType, Identifier, NewOrder,
    OrderStatus, RetryPolicy,
};
use rustls_pki_types::CertificateDer;
use serde::{Deserialize, de::DeserializeOwned};
use sha1::Sha1;
use time::OffsetDateTime;
use tokio::{
    sync::{RwLock, watch},
    time::sleep,
};
use zeroize::Zeroizing;

use super::{
    authority::AuthorityPool,
    config::{
        AcmeConfig, CertificateAuthorityKind, ChallengeConfig, DnsProviderKind,
        ValidatedCertificate, normalize_domain,
    },
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
    authorities: AuthorityPool,
    challenges: Arc<Http01ChallengeStore>,
    dns_providers: DnsProviderRegistry,
}

pub struct AcmeJobOutput {
    pub certificate_id: String,
    pub attempted_certificate: ValidatedCertificate,
    pub result: Result<Arc<CertifiedMaterial>, String>,
    pub cleanup_failures: Vec<PendingDnsCleanup>,
    pub cleanup_journal_error: Option<String>,
}

impl AcmeJobOutput {
    pub fn matches(&self, certificate: &ValidatedCertificate) -> bool {
        self.attempted_certificate == *certificate
    }
}

enum ProvisionedChallenge {
    Http01 { domain: String, token: String },
    Dns01 { cleanup: PendingDnsCleanup },
}

#[async_trait]
trait Dns01Provider: Send + Sync {
    async fn present(
        &self,
        credential: &DnsCredential,
        credential_id: &str,
        domain: &str,
        value: &str,
    ) -> Result<PendingDnsCleanup, Dns01PresentError>;

    async fn cleanup(
        &self,
        credential: &DnsCredential,
        cleanup: &PendingDnsCleanup,
    ) -> Result<(), String>;
}

#[derive(Clone)]
pub(super) enum DnsCredential {
    Cloudflare {
        api_token: Zeroizing<String>,
    },
    Aliyun {
        access_key_id: Zeroizing<String>,
        access_key_secret: Zeroizing<String>,
    },
}

struct DnsProviderRegistry {
    cloudflare: Arc<dyn Dns01Provider>,
    aliyun: Arc<dyn Dns01Provider>,
}

impl DnsProviderRegistry {
    fn production() -> Self {
        Self {
            cloudflare: Arc::new(CloudflareDnsProvider),
            aliyun: Arc::new(AliyunDnsProvider),
        }
    }

    #[cfg(test)]
    fn testing(provider: Arc<dyn Dns01Provider>) -> Self {
        Self {
            cloudflare: provider.clone(),
            aliyun: provider,
        }
    }

    fn provider(&self, kind: DnsProviderKind) -> &Arc<dyn Dns01Provider> {
        match kind {
            DnsProviderKind::Cloudflare => &self.cloudflare,
            DnsProviderKind::Aliyun => &self.aliyun,
        }
    }

    fn provider_for_cleanup(
        &self,
        cleanup: &PendingDnsCleanup,
    ) -> Result<&Arc<dyn Dns01Provider>, String> {
        match cleanup.provider.as_str() {
            "cloudflare" => Ok(&self.cloudflare),
            "aliyun" => Ok(&self.aliyun),
            provider => Err(format!("unsupported DNS cleanup provider {provider}")),
        }
    }
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
        credential: &DnsCredential,
        credential_id: &str,
        domain: &str,
        value: &str,
    ) -> Result<PendingDnsCleanup, Dns01PresentError> {
        let DnsCredential::Cloudflare { api_token } = credential else {
            return Err(Dns01PresentError {
                message: "Cloudflare DNS credential has the wrong provider type".to_string(),
                cleanup: None,
            });
        };
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

    async fn cleanup(
        &self,
        credential: &DnsCredential,
        cleanup: &PendingDnsCleanup,
    ) -> Result<(), String> {
        let DnsCredential::Cloudflare { api_token } = credential else {
            return Err("Cloudflare DNS credential has the wrong provider type".to_string());
        };
        delete_cloudflare_record(api_token, &cleanup.zone_id, &cleanup.record_id).await
    }
}

struct AliyunDnsProvider;

#[async_trait]
impl Dns01Provider for AliyunDnsProvider {
    async fn present(
        &self,
        credential: &DnsCredential,
        credential_id: &str,
        domain: &str,
        value: &str,
    ) -> Result<PendingDnsCleanup, Dns01PresentError> {
        let DnsCredential::Aliyun {
            access_key_id,
            access_key_secret,
        } = credential
        else {
            return Err(Dns01PresentError {
                message: "Aliyun DNS credential has the wrong provider type".to_string(),
                cleanup: None,
            });
        };
        let (cleanup, name_servers) = create_aliyun_dns01(
            access_key_id,
            access_key_secret,
            credential_id,
            domain,
            value,
        )
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

    async fn cleanup(
        &self,
        credential: &DnsCredential,
        cleanup: &PendingDnsCleanup,
    ) -> Result<(), String> {
        let DnsCredential::Aliyun {
            access_key_id,
            access_key_secret,
        } = credential
        else {
            return Err("Aliyun DNS credential has the wrong provider type".to_string());
        };
        delete_aliyun_record(access_key_id, access_key_secret, &cleanup.record_id).await
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
        let authorities = AuthorityPool::production();
        Arc::new(Self {
            config: RwLock::new(config),
            storage,
            authorities,
            challenges,
            dns_providers: DnsProviderRegistry::production(),
        })
    }

    #[cfg(test)]
    fn new_with_http(
        config: AcmeConfig,
        storage: GatewayStorage,
        challenges: Arc<Http01ChallengeStore>,
        authority: CertificateAuthorityKind,
        http: Box<dyn HttpClient>,
    ) -> Arc<Self> {
        let authorities = AuthorityPool::testing(authority, http);
        Arc::new(Self {
            config: RwLock::new(config),
            storage,
            authorities,
            challenges,
            dns_providers: DnsProviderRegistry::production(),
        })
    }

    #[cfg(test)]
    fn new_with_http_and_dns_provider(
        config: AcmeConfig,
        storage: GatewayStorage,
        challenges: Arc<Http01ChallengeStore>,
        authority: CertificateAuthorityKind,
        http: Box<dyn HttpClient>,
        dns_provider: Arc<dyn Dns01Provider>,
    ) -> Arc<Self> {
        let authorities = AuthorityPool::testing(authority, http);
        Arc::new(Self {
            config: RwLock::new(config),
            storage,
            authorities,
            challenges,
            dns_providers: DnsProviderRegistry::testing(dns_provider),
        })
    }

    pub async fn issue(
        &self,
        certificate: ValidatedCertificate,
        dns_credential: Option<DnsCredential>,
        current_leaf_der: Option<Vec<u8>>,
        mut cancellation: watch::Receiver<bool>,
    ) -> AcmeJobOutput {
        let certificate_id = certificate.id.clone();
        let dns_credential_ref = dns_credential.as_ref();
        let config = self.config.read().await.clone();
        let mut cleanup_failures = Vec::new();
        let mut cleanup_journal_error = None;
        let authority = certificate.authority;
        let challenge_name = challenge_name(&certificate.challenge);
        let result = match self
            .authorities
            .account(authority, &config, &self.storage)
            .await
        {
            Ok(account) => {
                let mut provisioned = Vec::new();
                let issue = self.issue_inner(
                    &account,
                    &certificate,
                    dns_credential_ref,
                    current_leaf_der.as_deref(),
                    &mut provisioned,
                );
                let attempt = tokio::select! {
                    result = issue => result,
                    changed = cancellation.changed() => {
                        match changed {
                            Ok(()) if *cancellation.borrow() => Err("ACME operation was cancelled".to_string()),
                            Ok(()) | Err(_) => Err("ACME cancellation channel closed".to_string()),
                        }
                    }
                };
                cleanup_failures.extend(
                    self.cleanup_challenges(provisioned, dns_credential_ref).await,
                );
                attempt
            }
            Err(error) => Err(format!("account: {error}")),
        }
        .map_err(|error| {
            format!(
                "{} / {challenge_name}: {error}",
                authority.display_name()
            )
        });
        if !cleanup_failures.is_empty() {
            cleanup_journal_error = self.storage.merge_cleanup_journal(&cleanup_failures).err();
        }
        AcmeJobOutput {
            certificate_id,
            attempted_certificate: certificate,
            result,
            cleanup_failures,
            cleanup_journal_error,
        }
    }

    pub async fn suggested_renewal_time(
        &self,
        material: &CertifiedMaterial,
    ) -> Result<Option<(OffsetDateTime, Duration)>, String> {
        let config = self.config.read().await.clone();
        let authority = material.metadata.authority;
        let account = self
            .authorities
            .account(authority, &config, &self.storage)
            .await?;
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
        let contact = config
            .contact_email
            .as_deref()
            .map(|email| format!("mailto:{email}"));
        let contacts = contact.as_deref().into_iter().collect::<Vec<_>>();
        self.authorities.update_contacts(&contacts).await?;
        *self.config.write().await = config;
        Ok(())
    }

    pub async fn retry_cleanup(
        &self,
        cleanup: &PendingDnsCleanup,
        credential: &DnsCredential,
    ) -> Result<(), String> {
        self.dns_providers
            .provider_for_cleanup(cleanup)?
            .cleanup(credential, cleanup)
            .await
    }

    async fn issue_inner(
        &self,
        account: &Account,
        certificate: &ValidatedCertificate,
        dns_credential: Option<&DnsCredential>,
        current_leaf_der: Option<&[u8]>,
        provisioned: &mut Vec<ProvisionedChallenge>,
    ) -> Result<Arc<CertifiedMaterial>, String> {
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
                    ChallengeConfig::Dns01 {
                        provider,
                        credential_id,
                    } => {
                        let credential = dns_credential.ok_or_else(|| {
                            format!(
                                "DNS credential {credential_id} is unavailable for certificate {}",
                                certificate.id
                            )
                        })?;
                        let domain = identifier.trim_start_matches("*.");
                        let dns_value = key_authorization.dns_value();
                        let cleanup = match self
                            .dns_providers
                            .provider(*provider)
                            .present(credential, credential_id, domain, &dns_value)
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
        self.storage
            .store_certificate(certificate, &certificate_chain_pem, &private_key_pem)
    }

    async fn cleanup_challenges(
        &self,
        provisioned: Vec<ProvisionedChallenge>,
        dns_credential: Option<&DnsCredential>,
    ) -> Vec<PendingDnsCleanup> {
        let mut failures = Vec::new();
        for challenge in provisioned {
            match challenge {
                ProvisionedChallenge::Http01 { domain, token } => {
                    self.challenges.remove(&domain, &token);
                }
                ProvisionedChallenge::Dns01 { cleanup } => {
                    let result = match dns_credential {
                        Some(credential) => match self.dns_providers.provider_for_cleanup(&cleanup)
                        {
                            Ok(provider) => provider.cleanup(credential, &cleanup).await,
                            Err(error) => Err(error),
                        },
                        None => Err("DNS credential is unavailable during cleanup".to_string()),
                    };
                    if result.is_err() {
                        failures.push(cleanup);
                    }
                }
            }
        }
        failures
    }
}

fn challenge_name(challenge: &ChallengeConfig) -> &'static str {
    match challenge {
        ChallengeConfig::Http01 => "HTTP-01",
        ChallengeConfig::Dns01 { .. } => "DNS-01",
    }
}

#[derive(Deserialize)]
struct AliyunDomainInfo {
    #[serde(rename = "DnsServers")]
    dns_servers: Option<AliyunDnsServers>,
}

#[derive(Deserialize)]
struct AliyunDnsServers {
    #[serde(rename = "DnsServer", default)]
    values: Vec<String>,
}

#[derive(Deserialize)]
struct AliyunAddRecordResponse {
    #[serde(rename = "RecordId")]
    record_id: String,
}

async fn create_aliyun_dns01(
    access_key_id: &str,
    access_key_secret: &str,
    credential_id: &str,
    domain: &str,
    value: &str,
) -> Result<(PendingDnsCleanup, Vec<String>), String> {
    let (zone, name_servers) =
        discover_aliyun_zone(access_key_id, access_key_secret, domain).await?;
    let record_name = format!("_acme-challenge.{domain}");
    let relative = record_name
        .strip_suffix(&format!(".{zone}"))
        .unwrap_or(&record_name);
    let response: AliyunAddRecordResponse = aliyun_request(
        access_key_id,
        access_key_secret,
        "AddDomainRecord",
        &[
            ("DomainName", zone.as_str()),
            ("RR", relative),
            ("Type", "TXT"),
            ("Value", value),
        ],
    )
    .await?;
    Ok((
        PendingDnsCleanup {
            provider: "aliyun".to_string(),
            credential_id: credential_id.to_string(),
            zone_id: zone,
            record_id: response.record_id,
            record_name,
        },
        name_servers,
    ))
}

async fn discover_aliyun_zone(
    access_key_id: &str,
    access_key_secret: &str,
    domain: &str,
) -> Result<(String, Vec<String>), String> {
    let labels = domain.split('.').collect::<Vec<_>>();
    for index in 0..labels.len().saturating_sub(1) {
        let candidate = labels[index..].join(".");
        let result: Result<AliyunDomainInfo, String> = aliyun_request(
            access_key_id,
            access_key_secret,
            "DescribeDomainInfo",
            &[("DomainName", candidate.as_str())],
        )
        .await;
        if let Ok(info) = result {
            let name_servers = info
                .dns_servers
                .map(|servers| servers.values)
                .unwrap_or_default();
            if name_servers.is_empty() {
                return Err(format!(
                    "Aliyun DNS zone {candidate} did not provide authoritative nameservers"
                ));
            }
            return Ok((candidate, name_servers));
        }
    }
    Err(format!("no Aliyun DNS zone covers {domain}"))
}

async fn delete_aliyun_record(
    access_key_id: &str,
    access_key_secret: &str,
    record_id: &str,
) -> Result<(), String> {
    let _: serde_json::Value = aliyun_request(
        access_key_id,
        access_key_secret,
        "DeleteDomainRecord",
        &[("RecordId", record_id)],
    )
    .await?;
    Ok(())
}

async fn aliyun_request<T: DeserializeOwned>(
    access_key_id: &str,
    access_key_secret: &str,
    action: &str,
    action_parameters: &[(&str, &str)],
) -> Result<T, String> {
    let timestamp = OffsetDateTime::now_utc()
        .replace_nanosecond(0)
        .map_err(|error| format!("failed to construct Aliyun request time: {error}"))?
        .format(&time::format_description::well_known::Rfc3339)
        .map_err(|error| format!("failed to format Aliyun request time: {error}"))?;
    let nonce = uuid::Uuid::new_v4().to_string();
    let mut parameters = std::collections::BTreeMap::from([
        ("AccessKeyId".to_string(), access_key_id.to_string()),
        ("Action".to_string(), action.to_string()),
        ("Format".to_string(), "JSON".to_string()),
        ("SignatureMethod".to_string(), "HMAC-SHA1".to_string()),
        ("SignatureNonce".to_string(), nonce),
        ("SignatureVersion".to_string(), "1.0".to_string()),
        ("Timestamp".to_string(), timestamp),
        ("Version".to_string(), "2015-01-09".to_string()),
    ]);
    for (key, value) in action_parameters {
        parameters.insert((*key).to_string(), (*value).to_string());
    }
    let signature = aliyun_signature(&parameters, access_key_secret)?;
    parameters.insert("Signature".to_string(), signature);

    let response = reqwest::Client::new()
        .post("https://alidns.aliyuncs.com/")
        .form(&parameters)
        .send()
        .await
        .map_err(|error| format!("Aliyun DNS request failed: {error}"))?;
    let status = response.status();
    let body = response
        .bytes()
        .await
        .map_err(|error| format!("failed to read Aliyun DNS response: {error}"))?;
    if !status.is_success() {
        return Err(format!("Aliyun DNS returned HTTP {status}"));
    }
    if let Ok(error) = serde_json::from_slice::<AliyunErrorResponse>(&body)
        && error.code.is_some()
    {
        return Err(format!(
            "Aliyun DNS request was rejected: {}",
            error.code.as_deref().unwrap_or("unknown error")
        ));
    }
    serde_json::from_slice(&body)
        .map_err(|error| format!("Aliyun DNS response was invalid: {error}"))
}

#[derive(Deserialize)]
struct AliyunErrorResponse {
    #[serde(rename = "Code")]
    code: Option<String>,
}

fn aliyun_encode(value: &str) -> String {
    url::form_urlencoded::byte_serialize(value.as_bytes())
        .collect::<String>()
        .replace('+', "%20")
        .replace('*', "%2A")
        .replace("%7E", "~")
}

fn aliyun_signature(
    parameters: &std::collections::BTreeMap<String, String>,
    access_key_secret: &str,
) -> Result<String, String> {
    let canonical_query = parameters
        .iter()
        .map(|(key, value)| format!("{}={}", aliyun_encode(key), aliyun_encode(value)))
        .collect::<Vec<_>>()
        .join("&");
    let string_to_sign = format!("POST&%2F&{}", aliyun_encode(&canonical_query));
    let mut mac = Hmac::<Sha1>::new_from_slice(format!("{access_key_secret}&").as_bytes())
        .map_err(|_| "failed to initialize Aliyun request signing".to_string())?;
    mac.update(string_to_sign.as_bytes());
    Ok(base64::engine::general_purpose::STANDARD.encode(mac.finalize().into_bytes()))
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
    use crate::gateway::config::{CertificateAuthorityKind, DnsProviderKind};

    #[test]
    fn aliyun_encoding_follows_rfc3986_rules() {
        assert_eq!(aliyun_encode("a b+c*~"), "a%20b%2Bc%2A~");
    }

    #[test]
    fn aliyun_signature_is_stable_for_fixed_parameters() {
        let parameters = std::collections::BTreeMap::from([
            ("AccessKeyId".to_string(), "testid".to_string()),
            ("Action".to_string(), "DescribeDomainInfo".to_string()),
            ("Format".to_string(), "JSON".to_string()),
        ]);

        assert_eq!(
            aliyun_signature(&parameters, "testsecret").unwrap(),
            "OGQcOUWTZczjcr/IKcdpEByndvs="
        );
    }

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
                    contact_email: Some("ops@example.com".to_string()),
                    terms_of_service_agreed: true,
                },
                storage.clone(),
                challenges.clone(),
                CertificateAuthorityKind::Letsencrypt,
                Box::new(mock),
            );
            let certificate = ValidatedCertificate {
                id: "http01-cert".to_string(),
                domains: vec!["app.acme.test".to_string()],
                authority: CertificateAuthorityKind::Letsencrypt,
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
                    contact_email: None,
                    terms_of_service_agreed: true,
                },
                storage.clone(),
                challenges,
                CertificateAuthorityKind::Letsencrypt,
                Box::new(mock_acme),
                mock_dns.clone(),
            );
            let certificate = ValidatedCertificate {
                id: "dns01-cert".to_string(),
                domains: vec!["*.acme.test".to_string()],
                authority: CertificateAuthorityKind::Letsencrypt,
                challenge: ChallengeConfig::Dns01 {
                    provider: DnsProviderKind::Cloudflare,
                    credential_id: "cf-main".to_string(),
                },
            };
            let (_shutdown_sender, shutdown) = watch::channel(false);

            let output = context
                .issue(
                    certificate,
                    Some(DnsCredential::Cloudflare {
                        api_token: Zeroizing::new("cloudflare-token".to_string()),
                    }),
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
    fn every_explicit_authority_and_challenge_combination_issues_without_fallback() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            for authority in [
                CertificateAuthorityKind::Letsencrypt,
                CertificateAuthorityKind::Zerossl,
            ] {
                for uses_dns01 in [false, true] {
                    let temp = tempfile::tempdir().unwrap();
                    let storage = GatewayStorage::initialize(temp.path().join("gateway")).unwrap();
                    let challenges = Http01ChallengeStore::new();
                    let mock_acme = if uses_dns01 {
                        MockAcmeClient::new_wildcard(challenges.clone())
                    } else {
                        MockAcmeClient::new(challenges.clone())
                    };
                    let mock_state = mock_acme.state.clone();
                    let mock_dns = Arc::new(MockDnsProvider::default());
                    let context = AcmeContext::new_with_http_and_dns_provider(
                        AcmeConfig {
                            contact_email: Some("ops@example.com".to_string()),
                            terms_of_service_agreed: true,
                        },
                        storage,
                        challenges,
                        authority,
                        Box::new(mock_acme),
                        mock_dns.clone(),
                    );
                    let challenge = if uses_dns01 {
                        ChallengeConfig::Dns01 {
                            provider: DnsProviderKind::Cloudflare,
                            credential_id: "cf-main".to_string(),
                        }
                    } else {
                        ChallengeConfig::Http01
                    };
                    let certificate = ValidatedCertificate {
                        id: format!("{authority:?}-{uses_dns01}"),
                        domains: vec![if uses_dns01 {
                            "*.acme.test".to_string()
                        } else {
                            "app.acme.test".to_string()
                        }],
                        authority,
                        challenge: challenge.clone(),
                    };
                    let dns_credential = uses_dns01.then(|| DnsCredential::Cloudflare {
                        api_token: Zeroizing::new("cloudflare-token".to_string()),
                    });
                    let (_shutdown_sender, shutdown) = watch::channel(false);

                    let material = context
                        .issue(certificate, dns_credential, None, shutdown)
                        .await
                        .result
                        .unwrap();

                    assert_eq!(material.metadata.authority, authority);
                    assert_eq!(material.metadata.challenge, challenge);
                    let state = mock_state.lock().unwrap();
                    assert_eq!(
                        state.challenge_was_provisioned, !uses_dns01,
                        "HTTP-01 state must only be touched for an explicit HTTP-01 policy"
                    );
                    assert_eq!(
                        mock_dns.state.lock().unwrap().presented.len(),
                        usize::from(uses_dns01),
                        "DNS-01 provider must only be called for an explicit DNS-01 policy"
                    );
                }
            }
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
                    contact_email: None,
                    terms_of_service_agreed: true,
                },
                storage.clone(),
                challenges,
                CertificateAuthorityKind::Letsencrypt,
                Box::new(mock_acme),
                Arc::new(FailingDnsProvider {
                    cleanup_attempted: cleanup_attempted.clone(),
                }),
            );
            let certificate = ValidatedCertificate {
                id: "failed-dns01-cert".to_string(),
                domains: vec!["app.acme.test".to_string()],
                authority: CertificateAuthorityKind::Letsencrypt,
                challenge: ChallengeConfig::Dns01 {
                    provider: DnsProviderKind::Cloudflare,
                    credential_id: "cf-main".to_string(),
                },
            };
            let (_shutdown_sender, shutdown) = watch::channel(false);

            let output = context
                .issue(
                    certificate,
                    Some(DnsCredential::Cloudflare {
                        api_token: Zeroizing::new("cloudflare-token".to_string()),
                    }),
                    None,
                    shutdown,
                )
                .await;
            assert_eq!(
                output.result.unwrap_err(),
                "Let's Encrypt / DNS-01: DNS-01 TXT record did not propagate"
            );
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
                ("GET", "/directory" | "/v2/DV90") => Ok(acme_json_response(
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
            credential: &DnsCredential,
            credential_id: &str,
            domain: &str,
            value: &str,
        ) -> Result<PendingDnsCleanup, Dns01PresentError> {
            let DnsCredential::Cloudflare { api_token } = credential else {
                panic!("expected Cloudflare credential");
            };
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
            _credential: &DnsCredential,
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
            _credential: &DnsCredential,
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
            _credential: &DnsCredential,
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
