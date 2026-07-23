use std::{sync::Arc, time::Duration};

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
use time::{
    OffsetDateTime,
    format_description::well_known::{Rfc2822, Rfc3339},
};
use tokio::sync::{RwLock, watch};
use zeroize::Zeroizing;

use super::{
    authority::AuthorityPool,
    config::{
        AcmeConfig, ChallengeConfig, DnsProviderKind, ValidatedCertificate, normalize_domain,
    },
    proxy::Http01ChallengeStore,
    status::{CertificateFailure, CertificateStage, FailureKind, FailureSource},
    storage::{GatewayStorage, PendingDnsCleanup},
    tls::CertifiedMaterial,
};

#[cfg(test)]
use super::config::CertificateAuthorityKind;

const ACME_POLL_TIMEOUT: Duration = Duration::from_secs(120);
const ALIYUN_API_URL: &str = "https://alidns.aliyuncs.com/";

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
    pub result: Result<IssuedCertificate, CertificateFailure>,
    pub cleanup_failures: Vec<PendingDnsCleanup>,
    pub cleanup_journal_error: Option<String>,
}

impl AcmeJobOutput {
    pub fn matches(&self, certificate: &ValidatedCertificate) -> bool {
        self.attempted_certificate == *certificate
    }
}

pub struct IssuedCertificate {
    pub material: Arc<CertifiedMaterial>,
    certificate_chain_pem: String,
    private_key_pem: Zeroizing<String>,
}

impl std::fmt::Debug for IssuedCertificate {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("IssuedCertificate")
            .field("material", &self.material)
            .finish_non_exhaustive()
    }
}

impl IssuedCertificate {
    pub fn commit(
        self,
        storage: &GatewayStorage,
        certificate: &ValidatedCertificate,
    ) -> Result<Arc<CertifiedMaterial>, String> {
        storage.commit_validated_certificate(
            certificate,
            &self.certificate_chain_pem,
            &self.private_key_pem,
            &self.material,
        )?;
        Ok(self.material)
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
    failure: DnsProviderFailure,
    cleanup: Option<PendingDnsCleanup>,
}

#[derive(Debug)]
struct DnsProviderFailure {
    source: FailureSource,
    kind: FailureKind,
    code: String,
    message: String,
    retry_at: Option<OffsetDateTime>,
    http_status: Option<u16>,
}

impl DnsProviderFailure {
    fn configuration(code: &str, message: impl Into<String>) -> Self {
        Self {
            source: FailureSource::Configuration,
            kind: FailureKind::UserActionRequired,
            code: code.to_string(),
            message: message.into(),
            retry_at: None,
            http_status: None,
        }
    }

    fn provider(
        kind: FailureKind,
        code: &str,
        message: impl Into<String>,
        retry_at: Option<OffsetDateTime>,
        http_status: Option<u16>,
    ) -> Self {
        Self {
            source: FailureSource::DnsProvider,
            kind,
            code: code.to_string(),
            message: message.into(),
            retry_at,
            http_status,
        }
    }

    fn into_certificate_failure(self, certificate: &ValidatedCertificate) -> CertificateFailure {
        let mut failure = attempt_failure(
            certificate,
            self.source,
            self.kind,
            &self.code,
            self.message,
        );
        failure.retry_at = self.retry_at.map(format_timestamp);
        failure.http_status = self.http_status;
        failure
    }
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
                failure: DnsProviderFailure::configuration(
                    "dns_credential_provider_mismatch",
                    "Cloudflare DNS credential has the wrong provider type",
                ),
                cleanup: None,
            });
        };
        create_cloudflare_dns01(api_token, credential_id, domain, value)
            .await
            .map_err(|failure| Dns01PresentError {
                failure,
                cleanup: None,
            })
    }

    async fn cleanup(
        &self,
        credential: &DnsCredential,
        cleanup: &PendingDnsCleanup,
    ) -> Result<(), String> {
        let DnsCredential::Cloudflare { api_token } = credential else {
            return Err("Cloudflare DNS credential has the wrong provider type".to_string());
        };
        delete_cloudflare_record(api_token, &cleanup.zone_id, &cleanup.record_id)
            .await
            .map_err(|failure| failure.message)
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
                failure: DnsProviderFailure::configuration(
                    "dns_credential_provider_mismatch",
                    "Aliyun DNS credential has the wrong provider type",
                ),
                cleanup: None,
            });
        };
        create_aliyun_dns01(
            access_key_id,
            access_key_secret,
            credential_id,
            domain,
            value,
        )
        .await
        .map_err(|failure| Dns01PresentError {
            failure,
            cleanup: None,
        })
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
        delete_aliyun_record(access_key_id, access_key_secret, &cleanup.record_id)
            .await
            .map_err(|failure| failure.message)
    }
}

#[derive(Clone, Debug)]
struct CloudflareZone {
    id: String,
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
        progress: impl Fn(CertificateStage) + Send + Sync,
    ) -> AcmeJobOutput {
        let certificate_id = certificate.id.clone();
        let dns_credential_ref = dns_credential.as_ref();
        let config = self.config.read().await.clone();
        let mut cleanup_failures = Vec::new();
        let mut cleanup_journal_error = None;
        let authority = certificate.authority;
        let challenge_name = challenge_name(&certificate.challenge);
        progress(CertificateStage::Account);
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
                    &progress,
                );
                let attempt = tokio::select! {
                    result = issue => result,
                    changed = cancellation.changed() => {
                        match changed {
                            Ok(()) if *cancellation.borrow() => Err(attempt_failure(
                                &certificate,
                                FailureSource::Runtime,
                                FailureKind::Interrupted,
                                "attempt_cancelled",
                                "ACME operation was cancelled".to_string(),
                            )),
                            Ok(()) | Err(_) => Err(attempt_failure(
                                &certificate,
                                FailureSource::Runtime,
                                FailureKind::Interrupted,
                                "cancellation_channel_closed",
                                "ACME cancellation channel closed".to_string(),
                            )),
                        }
                    }
                };
                if !provisioned.is_empty() {
                    progress(CertificateStage::Cleanup);
                    cleanup_failures.extend(
                        self.cleanup_challenges(provisioned, dns_credential_ref)
                            .await,
                    );
                }
                attempt
            }
            Err(error) => Err(attempt_failure(
                &certificate,
                FailureSource::AcmeAccount,
                classify_message(&error),
                "account_unavailable",
                error,
            )),
        }
        .map_err(|mut failure| {
            failure.message = format!(
                "{} / {challenge_name}: {}",
                authority.display_name(),
                failure.message
            );
            if failure.kind == FailureKind::RateLimited
                && let Some(until) = self.authorities.rate_limit_until(authority)
            {
                failure.retry_at = Some(
                    until
                        .format(&Rfc3339)
                        .unwrap_or_else(|_| "unknown".to_string()),
                );
            }
            failure
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
        *self.config.write().await = config;
        Ok(())
    }

    pub async fn sync_contacts(&self) -> Result<(), String> {
        let config = self.config.read().await.clone();
        let contact = config
            .contact_email
            .as_deref()
            .map(|email| format!("mailto:{email}"));
        let contacts = contact.as_deref().into_iter().collect::<Vec<_>>();
        self.authorities.update_contacts(&contacts).await?;
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
        progress: &(impl Fn(CertificateStage) + Send + Sync),
    ) -> Result<IssuedCertificate, CertificateFailure> {
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

        progress(CertificateStage::Ordering);
        let mut order = account.new_order(&new_order).await.map_err(|error| {
            acme_failure(
                certificate,
                FailureSource::AcmeOrder,
                "order_creation_failed",
                "Failed to create ACME order",
                error,
            )
        })?;
        {
            let mut authorizations = order.authorizations();
            while let Some(authorization) = authorizations.next().await {
                let mut authorization = authorization.map_err(|error| {
                    acme_failure(
                        certificate,
                        FailureSource::AcmeAuthorization,
                        "authorization_load_failed",
                        "Failed to load ACME authorization",
                        error,
                    )
                })?;
                match authorization.status {
                    AuthorizationStatus::Valid => continue,
                    AuthorizationStatus::Pending => {}
                    other => {
                        return Err(attempt_failure(
                            certificate,
                            FailureSource::AcmeAuthorization,
                            FailureKind::UserActionRequired,
                            "authorization_invalid",
                            format!("ACME authorization entered unexpected state {other:?}"),
                        ));
                    }
                }

                let challenge_type = match certificate.challenge {
                    ChallengeConfig::Http01 => ChallengeType::Http01,
                    ChallengeConfig::Dns01 { .. } => ChallengeType::Dns01,
                };
                let mut challenge =
                    authorization
                        .challenge(challenge_type.clone())
                        .ok_or_else(|| {
                            attempt_failure(
                                certificate,
                                FailureSource::AcmeAuthorization,
                                FailureKind::Permanent,
                                "challenge_not_offered",
                                format!("ACME server did not offer {challenge_type:?}"),
                            )
                        })?;
                let identifier = challenge.identifier().to_string();
                let key_authorization = challenge.key_authorization();
                progress(CertificateStage::ProvisioningChallenge);
                match &certificate.challenge {
                    ChallengeConfig::Http01 => {
                        let domain = normalize_domain(&identifier).map_err(|error| {
                            attempt_failure(
                                certificate,
                                FailureSource::Configuration,
                                FailureKind::Permanent,
                                "invalid_challenge_identifier",
                                error,
                            )
                        })?;
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
                        ..
                    } => {
                        let credential = dns_credential.ok_or_else(|| {
                            attempt_failure(
                                certificate,
                                FailureSource::Configuration,
                                FailureKind::UserActionRequired,
                                "dns_credential_unavailable",
                                format!(
                                    "DNS credential {credential_id} is unavailable for certificate {}",
                                    certificate.id
                                ),
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
                                return Err(error.failure.into_certificate_failure(certificate));
                            }
                        };
                        provisioned.push(ProvisionedChallenge::Dns01 {
                            cleanup: cleanup.clone(),
                        });
                    }
                }
                progress(CertificateStage::Validating);
                challenge.set_ready().await.map_err(|error| {
                    acme_failure(
                        certificate,
                        FailureSource::AcmeAuthorization,
                        "challenge_ready_failed",
                        "Failed to mark ACME challenge ready",
                        error,
                    )
                })?;
            }
        }

        let retry = RetryPolicy::new().timeout(ACME_POLL_TIMEOUT);
        progress(CertificateStage::Validating);
        let status = order.poll_ready(&retry).await.map_err(|error| {
            acme_failure(
                certificate,
                FailureSource::AcmeAuthorization,
                "authorization_poll_failed",
                "Failed while waiting for ACME authorization",
                error,
            )
        })?;
        if status != OrderStatus::Ready {
            return Err(attempt_failure(
                certificate,
                FailureSource::AcmeAuthorization,
                FailureKind::UserActionRequired,
                "order_not_ready",
                format!("ACME order did not become ready: {status:?}"),
            ));
        }

        progress(CertificateStage::Finalizing);
        let private_key_pem = Zeroizing::new(order.finalize().await.map_err(|error| {
            acme_failure(
                certificate,
                FailureSource::AcmeFinalize,
                "finalize_failed",
                "Failed to finalize ACME order",
                error,
            )
        })?);
        progress(CertificateStage::Downloading);
        let certificate_chain_pem = order.poll_certificate(&retry).await.map_err(|error| {
            acme_failure(
                certificate,
                FailureSource::CertificateDownload,
                "certificate_download_failed",
                "Failed to retrieve ACME certificate",
                error,
            )
        })?;
        let material = Arc::new(
            CertifiedMaterial::from_pem_with_policy(
                &certificate_chain_pem,
                &private_key_pem,
                &certificate.domains,
                certificate.authority,
                certificate.challenge.clone(),
            )
            .map_err(|error| {
                attempt_failure(
                    certificate,
                    FailureSource::CertificateValidation,
                    FailureKind::Permanent,
                    "issued_certificate_invalid",
                    error,
                )
            })?,
        );
        Ok(IssuedCertificate {
            material,
            certificate_chain_pem,
            private_key_pem,
        })
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

fn format_timestamp(value: OffsetDateTime) -> String {
    value
        .format(&Rfc3339)
        .unwrap_or_else(|_| "unknown".to_string())
}

fn attempt_failure(
    certificate: &ValidatedCertificate,
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
        occurred_at: OffsetDateTime::now_utc()
            .format(&Rfc3339)
            .unwrap_or_else(|_| "unknown".to_string()),
        retry_at: None,
        authority: Some(certificate.authority),
        challenge: Some(challenge_name(&certificate.challenge).to_string()),
        dns_provider: certificate.challenge.dns01().map(|(provider, _)| provider),
        acme_problem_type: None,
        http_status: None,
    }
}

fn acme_failure(
    certificate: &ValidatedCertificate,
    stage_source: FailureSource,
    code: &str,
    context: &str,
    error: instant_acme::Error,
) -> CertificateFailure {
    let (source, kind, problem_type, http_status) = match &error {
        instant_acme::Error::Api(problem) => {
            let problem_name = problem
                .r#type
                .as_deref()
                .and_then(|value| value.rsplit(':').next());
            let kind = if problem.status == Some(429) || problem_name == Some("rateLimited") {
                FailureKind::RateLimited
            } else if matches!(
                problem_name,
                Some(
                    "unauthorized"
                        | "rejectedIdentifier"
                        | "userActionRequired"
                        | "accountDoesNotExist"
                        | "externalAccountRequired"
                        | "malformed"
                )
            ) || problem
                .status
                .is_some_and(|status| (400..500).contains(&status))
            {
                FailureKind::UserActionRequired
            } else {
                FailureKind::Transient
            };
            (stage_source, kind, problem.r#type.clone(), problem.status)
        }
        instant_acme::Error::Timeout(_) => (stage_source, FailureKind::Transient, None, None),
        instant_acme::Error::Http(_)
        | instant_acme::Error::Hyper(_)
        | instant_acme::Error::Other(_) => {
            (FailureSource::Network, FailureKind::Transient, None, None)
        }
        instant_acme::Error::Unsupported(_) => (stage_source, FailureKind::Permanent, None, None),
        instant_acme::Error::Crypto
        | instant_acme::Error::KeyRejected
        | instant_acme::Error::InvalidUri(_)
        | instant_acme::Error::Json(_)
        | instant_acme::Error::Str(_) => (stage_source, FailureKind::Permanent, None, None),
        _ => (stage_source, FailureKind::Transient, None, None),
    };
    let mut failure = attempt_failure(
        certificate,
        source,
        kind,
        code,
        format!("{context}: {error}"),
    );
    failure.acme_problem_type = problem_type;
    failure.http_status = http_status;
    failure
}

fn classify_message(message: &str) -> FailureKind {
    let normalized = message.to_ascii_lowercase();
    if normalized.contains("http 429") || normalized.contains("rate limit") {
        FailureKind::RateLimited
    } else if normalized.contains("failed to read acme account credentials")
        || normalized.contains("failed to decode acme account credentials")
        || normalized.contains("failed to store acme account credentials")
        || normalized.contains("failed to create acme http client")
        || normalized.contains("failed to create eab http client")
        || normalized.contains("hmac key was not valid")
        || normalized.contains("certificate authority") && normalized.contains("unavailable")
    {
        FailureKind::Permanent
    } else if normalized.contains("credential")
        || normalized.contains("unauthorized")
        || normalized.contains("forbidden")
        || normalized.contains("contact email is required")
        || normalized.contains("terms of service")
        || normalized.contains("http 401")
        || normalized.contains("http 403")
        || normalized.contains("no active cloudflare zone")
        || normalized.contains("no aliyun dns zone")
        || (400..500).any(|status| normalized.contains(&format!("http {status}")))
    {
        FailureKind::UserActionRequired
    } else {
        FailureKind::Transient
    }
}

#[derive(Deserialize)]
struct AliyunAddRecordResponse {
    #[serde(rename = "RecordId")]
    record_id: String,
}

#[derive(Deserialize)]
struct AliyunDescribeRecordsResponse {
    #[serde(rename = "DomainRecords")]
    domain_records: AliyunDomainRecords,
}

#[derive(Deserialize)]
struct AliyunDomainRecords {
    #[serde(rename = "Record", default)]
    records: Vec<AliyunDomainRecord>,
}

#[derive(Deserialize)]
struct AliyunDomainRecord {
    #[serde(rename = "RecordId")]
    record_id: String,
    #[serde(rename = "RR")]
    relative_name: String,
    #[serde(rename = "Type")]
    record_type: String,
    #[serde(rename = "Value")]
    value: String,
    #[serde(rename = "Status")]
    status: Option<String>,
}

async fn create_aliyun_dns01(
    access_key_id: &str,
    access_key_secret: &str,
    credential_id: &str,
    domain: &str,
    value: &str,
) -> Result<PendingDnsCleanup, DnsProviderFailure> {
    create_aliyun_dns01_at(
        access_key_id,
        access_key_secret,
        credential_id,
        domain,
        value,
        ALIYUN_API_URL,
    )
    .await
}

async fn create_aliyun_dns01_at(
    access_key_id: &str,
    access_key_secret: &str,
    credential_id: &str,
    domain: &str,
    value: &str,
    endpoint: &str,
) -> Result<PendingDnsCleanup, DnsProviderFailure> {
    let zone = discover_aliyun_zone_at(access_key_id, access_key_secret, domain, endpoint).await?;
    let record_name = format!("_acme-challenge.{domain}");
    let relative = record_name
        .strip_suffix(&format!(".{zone}"))
        .unwrap_or(&record_name);
    let add_result: Result<AliyunAddRecordResponse, DnsProviderFailure> = aliyun_request_at(
        access_key_id,
        access_key_secret,
        "AddDomainRecord",
        &[
            ("DomainName", zone.as_str()),
            ("RR", relative),
            ("Type", "TXT"),
            ("Value", value),
        ],
        endpoint,
    )
    .await;
    let record_id = match add_result {
        Ok(response) => response.record_id,
        Err(error) if aliyun_record_duplicate(&error.code) => {
            recover_aliyun_duplicate_record(
                access_key_id,
                access_key_secret,
                &zone,
                relative,
                value,
                endpoint,
            )
            .await?
        }
        Err(error) => return Err(error),
    };
    Ok(PendingDnsCleanup {
        provider: "aliyun".to_string(),
        credential_id: credential_id.to_string(),
        zone_id: zone,
        record_id,
        record_name,
        attempt_count: 0,
        next_attempt_at: None,
        last_error: None,
    })
}

async fn discover_aliyun_zone_at(
    access_key_id: &str,
    access_key_secret: &str,
    domain: &str,
    endpoint: &str,
) -> Result<String, DnsProviderFailure> {
    let labels = domain.split('.').collect::<Vec<_>>();
    for index in 0..labels.len().saturating_sub(1) {
        let candidate = labels[index..].join(".");
        let result: Result<serde_json::Value, DnsProviderFailure> = aliyun_request_at(
            access_key_id,
            access_key_secret,
            "DescribeDomainInfo",
            &[("DomainName", candidate.as_str())],
            endpoint,
        )
        .await;
        match result {
            Ok(_) => return Ok(candidate),
            Err(error) if aliyun_zone_missing(&error.code) => continue,
            Err(error) => return Err(error),
        }
    }
    Err(DnsProviderFailure::provider(
        FailureKind::UserActionRequired,
        "dns_zone_not_found",
        format!("no Aliyun DNS zone covers {domain}"),
        None,
        None,
    ))
}

async fn recover_aliyun_duplicate_record(
    access_key_id: &str,
    access_key_secret: &str,
    zone: &str,
    relative: &str,
    value: &str,
    endpoint: &str,
) -> Result<String, DnsProviderFailure> {
    let response: AliyunDescribeRecordsResponse = aliyun_request_at(
        access_key_id,
        access_key_secret,
        "DescribeDomainRecords",
        &[
            ("DomainName", zone),
            ("RRKeyWord", relative),
            ("TypeKeyWord", "TXT"),
            ("SearchMode", "EXACT"),
            ("PageSize", "500"),
        ],
        endpoint,
    )
    .await?;
    let Some(record) = response.domain_records.records.into_iter().find(|record| {
        record.relative_name == relative
            && record.record_type.eq_ignore_ascii_case("TXT")
            && record.value == value
    }) else {
        return Err(DnsProviderFailure::provider(
            FailureKind::UserActionRequired,
            "dns_record_conflict",
            format!("Aliyun DNS already contains a conflicting TXT record for {relative}.{zone}"),
            None,
            Some(400),
        ));
    };
    if record
        .status
        .as_deref()
        .is_some_and(|status| status.eq_ignore_ascii_case("DISABLE"))
    {
        let _: serde_json::Value = aliyun_request_at(
            access_key_id,
            access_key_secret,
            "SetDomainRecordStatus",
            &[
                ("RecordId", record.record_id.as_str()),
                ("Status", "ENABLE"),
            ],
            endpoint,
        )
        .await?;
    }
    Ok(record.record_id)
}

async fn delete_aliyun_record(
    access_key_id: &str,
    access_key_secret: &str,
    record_id: &str,
) -> Result<(), DnsProviderFailure> {
    delete_aliyun_record_at(access_key_id, access_key_secret, record_id, ALIYUN_API_URL).await
}

async fn delete_aliyun_record_at(
    access_key_id: &str,
    access_key_secret: &str,
    record_id: &str,
    endpoint: &str,
) -> Result<(), DnsProviderFailure> {
    let result: Result<serde_json::Value, DnsProviderFailure> = aliyun_request_at(
        access_key_id,
        access_key_secret,
        "DeleteDomainRecord",
        &[("RecordId", record_id)],
        endpoint,
    )
    .await;
    match result {
        Ok(_) => Ok(()),
        Err(error) if aliyun_record_missing(&error.code) => Ok(()),
        Err(error) => Err(error),
    }
}

async fn aliyun_request_at<T: DeserializeOwned>(
    access_key_id: &str,
    access_key_secret: &str,
    action: &str,
    action_parameters: &[(&str, &str)],
    endpoint: &str,
) -> Result<T, DnsProviderFailure> {
    let timestamp = OffsetDateTime::now_utc()
        .replace_nanosecond(0)
        .map_err(|error| {
            DnsProviderFailure::provider(
                FailureKind::Permanent,
                "aliyun_request_time_failed",
                format!("failed to construct Aliyun request time: {error}"),
                None,
                None,
            )
        })?
        .format(&time::format_description::well_known::Rfc3339)
        .map_err(|error| {
            DnsProviderFailure::provider(
                FailureKind::Permanent,
                "aliyun_request_time_failed",
                format!("failed to format Aliyun request time: {error}"),
                None,
                None,
            )
        })?;
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
    let signature = aliyun_signature(&parameters, access_key_secret).map_err(|error| {
        DnsProviderFailure::provider(
            FailureKind::Permanent,
            "aliyun_request_signing_failed",
            error,
            None,
            None,
        )
    })?;
    parameters.insert("Signature".to_string(), signature);

    let response = reqwest::Client::new()
        .post(endpoint)
        .form(&parameters)
        .send()
        .await
        .map_err(|error| {
            DnsProviderFailure::provider(
                FailureKind::Transient,
                "aliyun_request_failed",
                format!("Aliyun DNS request failed: {error}"),
                None,
                None,
            )
        })?;
    let status = response.status();
    let retry_at = response
        .headers()
        .get(reqwest::header::RETRY_AFTER)
        .and_then(|value| value.to_str().ok())
        .and_then(parse_provider_retry_after);
    let body = response.bytes().await.map_err(|error| {
        DnsProviderFailure::provider(
            FailureKind::Transient,
            "aliyun_response_read_failed",
            format!("failed to read Aliyun DNS response: {error}"),
            None,
            Some(status.as_u16()),
        )
    })?;
    let api_error = serde_json::from_slice::<AliyunErrorResponse>(&body).ok();
    if !status.is_success() || api_error.as_ref().is_some_and(|error| error.code.is_some()) {
        return Err(aliyun_api_failure(status, api_error.as_ref(), retry_at));
    }
    serde_json::from_slice(&body).map_err(|error| {
        DnsProviderFailure::provider(
            FailureKind::Transient,
            "aliyun_response_invalid",
            format!("Aliyun DNS response was invalid: {error}"),
            None,
            Some(status.as_u16()),
        )
    })
}

#[derive(Deserialize)]
struct AliyunErrorResponse {
    #[serde(rename = "Code")]
    code: Option<String>,
    #[serde(rename = "Message")]
    message: Option<String>,
}

fn aliyun_api_failure(
    status: reqwest::StatusCode,
    error: Option<&AliyunErrorResponse>,
    retry_at: Option<OffsetDateTime>,
) -> DnsProviderFailure {
    let provider_code = error
        .and_then(|error| error.code.as_deref())
        .unwrap_or("aliyun_request_rejected");
    let normalized_code = provider_code.to_ascii_lowercase();
    let kind = if status.as_u16() == 429
        || normalized_code.contains("throttl")
        || normalized_code.contains("flowcontrol")
        || normalized_code.contains("rate")
    {
        FailureKind::RateLimited
    } else if status.as_u16() == 401
        || status.as_u16() == 403
        || (400..500).contains(&status.as_u16())
        || normalized_code.contains("accesskey")
        || normalized_code.contains("signature")
        || normalized_code.contains("forbidden")
        || normalized_code.contains("unauthorized")
    {
        FailureKind::UserActionRequired
    } else {
        FailureKind::Transient
    };
    let retry_at = (kind == FailureKind::RateLimited)
        .then(|| retry_at.unwrap_or_else(|| OffsetDateTime::now_utc() + time::Duration::hours(1)));
    let provider_message = error
        .and_then(|error| error.message.as_deref())
        .unwrap_or("request rejected");
    DnsProviderFailure::provider(
        kind,
        provider_code,
        format!("Aliyun DNS returned HTTP {status}: {provider_message} ({provider_code})"),
        retry_at,
        Some(status.as_u16()),
    )
}

fn aliyun_zone_missing(code: &str) -> bool {
    let normalized = code.to_ascii_lowercase();
    normalized.contains("domainname")
        && (normalized.contains("noexist")
            || normalized.contains("notexist")
            || normalized.contains("notfound"))
}

fn aliyun_record_duplicate(code: &str) -> bool {
    code.eq_ignore_ascii_case("DomainRecordDuplicate")
}

fn aliyun_record_missing(code: &str) -> bool {
    let normalized = code.to_ascii_lowercase();
    normalized.contains("recordid")
        && (normalized.contains("noexist")
            || normalized.contains("notexist")
            || normalized.contains("notfound"))
}

fn parse_provider_retry_after(value: &str) -> Option<OffsetDateTime> {
    if let Ok(seconds) = value.trim().parse::<i64>() {
        return Some(OffsetDateTime::now_utc() + time::Duration::seconds(seconds.max(0)));
    }
    OffsetDateTime::parse(value.trim(), &Rfc2822).ok()
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
) -> Result<PendingDnsCleanup, DnsProviderFailure> {
    let client = cloudflare_client(api_token)?;
    create_cloudflare_dns01_with_client(&client, credential_id, domain, value).await
}

async fn create_cloudflare_dns01_with_client(
    client: &CloudflareClient,
    credential_id: &str,
    domain: &str,
    value: &str,
) -> Result<PendingDnsCleanup, DnsProviderFailure> {
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
        .map_err(|error| cloudflare_failure("Cloudflare TXT creation failed", error))?;
    let cleanup = PendingDnsCleanup {
        provider: "cloudflare".to_string(),
        credential_id: credential_id.to_string(),
        zone_id: zone.id,
        record_id: response.result.id,
        record_name: record_name.clone(),
        attempt_count: 0,
        next_attempt_at: None,
        last_error: None,
    };

    Ok(cleanup)
}

async fn discover_cloudflare_zone(
    client: &CloudflareClient,
    domain: &str,
) -> Result<CloudflareZone, DnsProviderFailure> {
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
            .map_err(|error| cloudflare_failure("Cloudflare zone discovery failed", error))?;
        if let Some(zone) = response.result.into_iter().next() {
            return Ok(CloudflareZone { id: zone.id });
        }
    }
    Err(DnsProviderFailure::provider(
        FailureKind::UserActionRequired,
        "dns_zone_not_found",
        format!("no active Cloudflare zone covers {domain}"),
        None,
        None,
    ))
}

async fn delete_cloudflare_record(
    api_token: &str,
    zone_id: &str,
    record_id: &str,
) -> Result<(), DnsProviderFailure> {
    let client = cloudflare_client(api_token)?;
    delete_cloudflare_record_with_client(&client, zone_id, record_id).await
}

async fn delete_cloudflare_record_with_client(
    client: &CloudflareClient,
    zone_id: &str,
    record_id: &str,
) -> Result<(), DnsProviderFailure> {
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
        .map_err(|error| cloudflare_failure("Cloudflare TXT cleanup failed", error))
}

fn cloudflare_client(api_token: &str) -> Result<CloudflareClient, DnsProviderFailure> {
    cloudflare_client_with_environment(api_token, Environment::Production)
}

fn cloudflare_client_with_environment(
    api_token: &str,
    environment: Environment,
) -> Result<CloudflareClient, DnsProviderFailure> {
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
    .map_err(|error| {
        DnsProviderFailure::provider(
            FailureKind::Permanent,
            "cloudflare_client_initialization_failed",
            format!("failed to create Cloudflare API client: {error}"),
            None,
            None,
        )
    })
}

fn cloudflare_failure(context: &str, error: ApiFailure) -> DnsProviderFailure {
    match &error {
        ApiFailure::Error(status, _) => {
            let kind = match status.as_u16() {
                429 => FailureKind::RateLimited,
                400..=499 => FailureKind::UserActionRequired,
                _ => FailureKind::Transient,
            };
            let code = match kind {
                FailureKind::RateLimited => "cloudflare_rate_limited",
                FailureKind::UserActionRequired => "cloudflare_request_rejected",
                _ => "cloudflare_provider_unavailable",
            };
            let retry_at = (kind == FailureKind::RateLimited)
                .then(|| OffsetDateTime::now_utc() + time::Duration::hours(1));
            DnsProviderFailure::provider(
                kind,
                code,
                format!("{context}: {error}"),
                retry_at,
                Some(status.as_u16()),
            )
        }
        ApiFailure::Invalid(_) => DnsProviderFailure::provider(
            FailureKind::Transient,
            "cloudflare_request_failed",
            format!("{context}: {error}"),
            None,
            None,
        ),
    }
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
    fn aliyun_dns01_reuses_duplicate_txt_and_cleanup_is_idempotent() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let endpoint = format!("http://{}/", listener.local_addr().unwrap());
            let requests = Arc::new(TokioMutex::new(Vec::new()));
            let server_requests = requests.clone();
            let (finished_sender, finished_receiver) = oneshot::channel();
            tokio::spawn(async move {
                for _ in 0..5 {
                    let (mut stream, _) = listener.accept().await.unwrap();
                    let request = read_http_request(&mut stream).await;
                    let parameters = aliyun_request_parameters(&request);
                    let response = match parameters.get("Action").map(String::as_str) {
                        Some("DescribeDomainInfo") => aliyun_response(json!({}), 200),
                        Some("AddDomainRecord") => aliyun_response(
                            json!({
                                "Code": "DomainRecordDuplicate",
                                "Message": "The DNS record already exists."
                            }),
                            400,
                        ),
                        Some("DescribeDomainRecords") => aliyun_response(
                            json!({
                                "DomainRecords": {
                                    "Record": [
                                        {
                                            "RecordId": "other-challenge",
                                            "RR": "_acme-challenge",
                                            "Type": "TXT",
                                            "Value": "different-proof",
                                            "Status": "ENABLE"
                                        },
                                        {
                                            "RecordId": "existing-record",
                                            "RR": "_acme-challenge",
                                            "Type": "TXT",
                                            "Value": "dns-proof",
                                            "Status": "DISABLE"
                                        }
                                    ]
                                }
                            }),
                            200,
                        ),
                        Some("SetDomainRecordStatus") => aliyun_response(
                            json!({
                                "RecordId": "existing-record",
                                "Status": "ENABLE"
                            }),
                            200,
                        ),
                        Some("DeleteDomainRecord") => aliyun_response(
                            json!({
                                "Code": "InvalidRecordId.NotFound",
                                "Message": "The DNS record does not exist."
                            }),
                            400,
                        ),
                        action => panic!("unexpected Aliyun action: {action:?}"),
                    };
                    server_requests.lock().await.push(parameters);
                    stream.write_all(response.as_bytes()).await.unwrap();
                }
                let _ = finished_sender.send(());
            });

            let cleanup = create_aliyun_dns01_at(
                "access-key",
                "access-secret",
                "aliyun-main",
                "example.com",
                "dns-proof",
                &endpoint,
            )
            .await
            .unwrap();
            assert_eq!(cleanup.zone_id, "example.com");
            assert_eq!(cleanup.record_id, "existing-record");
            assert_eq!(cleanup.record_name, "_acme-challenge.example.com");

            delete_aliyun_record_at("access-key", "access-secret", &cleanup.record_id, &endpoint)
                .await
                .unwrap();
            finished_receiver.await.unwrap();

            let requests = requests.lock().await;
            assert_eq!(
                requests
                    .iter()
                    .filter_map(|request| request.get("Action"))
                    .map(String::as_str)
                    .collect::<Vec<_>>(),
                [
                    "DescribeDomainInfo",
                    "AddDomainRecord",
                    "DescribeDomainRecords",
                    "SetDomainRecordStatus",
                    "DeleteDomainRecord",
                ]
            );
            let describe = &requests[2];
            assert_eq!(
                describe.get("RRKeyWord").map(String::as_str),
                Some("_acme-challenge")
            );
            assert_eq!(describe.get("TypeKeyWord").map(String::as_str), Some("TXT"));
            assert_eq!(
                describe.get("SearchMode").map(String::as_str),
                Some("EXACT")
            );
            let enable = &requests[3];
            assert_eq!(
                enable.get("RecordId").map(String::as_str),
                Some("existing-record")
            );
            assert_eq!(enable.get("Status").map(String::as_str), Some("ENABLE"));
        });
    }

    #[test]
    fn dns_provider_rate_limits_keep_typed_retry_metadata() {
        let cloudflare = cloudflare_failure(
            "Cloudflare request failed",
            ApiFailure::Error(reqwest::StatusCode::TOO_MANY_REQUESTS, Default::default()),
        );
        assert_eq!(cloudflare.source, FailureSource::DnsProvider);
        assert_eq!(cloudflare.kind, FailureKind::RateLimited);
        assert_eq!(cloudflare.code, "cloudflare_rate_limited");
        assert_eq!(cloudflare.http_status, Some(429));
        assert!(cloudflare.retry_at.is_some());

        let aliyun_error = AliyunErrorResponse {
            code: Some("Throttling.User".to_string()),
            message: Some("too many requests".to_string()),
        };
        let aliyun = aliyun_api_failure(
            reqwest::StatusCode::TOO_MANY_REQUESTS,
            Some(&aliyun_error),
            Some(OffsetDateTime::now_utc() + time::Duration::minutes(5)),
        );
        assert_eq!(aliyun.source, FailureSource::DnsProvider);
        assert_eq!(aliyun.kind, FailureKind::RateLimited);
        assert_eq!(aliyun.code, "Throttling.User");
        assert_eq!(aliyun.http_status, Some(429));
        assert!(aliyun.retry_at.is_some());
    }

    #[test]
    fn zerossl_account_requirements_do_not_enter_network_retry_loops() {
        assert_eq!(
            classify_message("certificate contact email is required"),
            FailureKind::UserActionRequired
        );
        assert_eq!(
            classify_message("ZeroSSL EAB request returned HTTP 400 Bad Request"),
            FailureKind::UserActionRequired
        );
        assert_eq!(
            classify_message("ZeroSSL EAB HMAC key was not valid URL-safe Base64"),
            FailureKind::Permanent
        );
        assert_eq!(
            classify_message("failed to decode ACME account credentials"),
            FailureKind::Permanent
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
    fn cloudflare_dns01_manages_txt_record_without_authoritative_lookup() {
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
            let cleanup = create_cloudflare_dns01_with_client(
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
    fn instant_acme_http01_flow_only_persists_after_coordinator_commit() {
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
            let stages = Arc::new(StdMutex::new(Vec::new()));
            let reported_stages = stages.clone();

            let output = context
                .issue(certificate.clone(), None, None, shutdown, move |stage| {
                    reported_stages.lock().unwrap().push(stage);
                })
                .await;
            let issued = output.result.unwrap();
            assert_eq!(issued.material.metadata.domains, ["app.acme.test"]);
            assert!(output.cleanup_failures.is_empty());
            assert!(output.cleanup_journal_error.is_none());
            assert!(challenges.get("app.acme.test", "http01-token").is_none());
            let stages = stages.lock().unwrap();
            for expected in [
                CertificateStage::Account,
                CertificateStage::Ordering,
                CertificateStage::ProvisioningChallenge,
                CertificateStage::Validating,
                CertificateStage::Finalizing,
                CertificateStage::Downloading,
                CertificateStage::Cleanup,
            ] {
                assert!(
                    stages.contains(&expected),
                    "missing ACME stage {expected:?}"
                );
            }
            drop(stages);
            assert!(
                storage
                    .load_certificate("http01-cert", &["app.acme.test".to_string()])
                    .unwrap()
                    .is_none()
            );
            let material = issued.commit(&storage, &certificate).unwrap();
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
                    |_| {},
                )
                .await
                .result
                .unwrap();
            assert_ne!(renewal.material.metadata.leaf_der, first_leaf);

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
                    credential_revision: 1,
                },
            };
            let (_shutdown_sender, shutdown) = watch::channel(false);

            let output = context
                .issue(
                    certificate.clone(),
                    Some(DnsCredential::Cloudflare {
                        api_token: Zeroizing::new("cloudflare-token".to_string()),
                    }),
                    None,
                    shutdown,
                    |_| {},
                )
                .await;
            let issued = output.result.unwrap();
            assert!(output.cleanup_failures.is_empty());
            issued.commit(&storage, &certificate).unwrap();
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
                            credential_revision: 1,
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
                        .issue(certificate, dns_credential, None, shutdown, |_| {})
                        .await
                        .result
                        .unwrap();

                    assert_eq!(material.material.metadata.authority, authority);
                    assert_eq!(material.material.metadata.challenge, challenge);
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
    fn dns01_partial_presentation_failure_persists_failed_cleanup() {
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
                    credential_revision: 1,
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
                    |_| {},
                )
                .await;
            let failure = output.result.unwrap_err();
            assert_eq!(failure.source, FailureSource::DnsProvider);
            assert_eq!(failure.kind, FailureKind::Transient);
            assert!(
                failure
                    .message
                    .contains("Let's Encrypt / DNS-01: simulated DNS provider failure")
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
                attempt_count: 0,
                next_attempt_at: None,
                last_error: None,
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
                failure: DnsProviderFailure::provider(
                    FailureKind::Transient,
                    "dns_provider_partial_failure",
                    "simulated DNS provider failure",
                    None,
                    None,
                ),
                cleanup: Some(PendingDnsCleanup {
                    provider: "cloudflare".to_string(),
                    credential_id: credential_id.to_string(),
                    zone_id: "orphan-zone".to_string(),
                    record_id: "orphan-record".to_string(),
                    record_name: format!("_acme-challenge.{domain}"),
                    attempt_count: 0,
                    next_attempt_at: None,
                    last_error: None,
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

    fn aliyun_response(body: Value, status: u16) -> String {
        let body = body.to_string();
        let reason = if status == 200 { "OK" } else { "Bad Request" };
        format!(
            "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
    }

    fn aliyun_request_parameters(request: &str) -> std::collections::BTreeMap<String, String> {
        let body = request.split("\r\n\r\n").nth(1).unwrap_or_default();
        url::form_urlencoded::parse(body.as_bytes())
            .into_owned()
            .collect()
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
