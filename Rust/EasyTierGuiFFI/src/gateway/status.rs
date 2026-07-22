use serde::{Deserialize, Serialize};

use super::config::{
    CertificateAuthorityKind, DeploymentIdentity, DnsProviderKind, GATEWAY_SCHEMA_VERSION,
};

#[derive(Clone, Copy, Debug, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GatewayState {
    #[default]
    Stopped,
    #[allow(dead_code)]
    Starting,
    Running,
    Stopping,
    Failed,
}

#[derive(Clone, Debug, Serialize)]
pub struct GatewayStatusSnapshot {
    pub schema_version: u32,
    pub state: GatewayState,
    pub applied_deployment: Option<DeploymentIdentity>,
    pub listeners: ListenerStatus,
    pub routes: Vec<RouteStatus>,
    pub certificates: Vec<CertificateStatus>,
    pub pending_dns_cleanups: usize,
    pub provider_cooldowns: Vec<ProviderCooldownStatus>,
    pub runtime_issues: Vec<RuntimeIssue>,
}

impl Default for GatewayStatusSnapshot {
    fn default() -> Self {
        Self {
            schema_version: GATEWAY_SCHEMA_VERSION,
            state: GatewayState::Stopped,
            applied_deployment: None,
            listeners: ListenerStatus::default(),
            routes: Vec::new(),
            certificates: Vec::new(),
            pending_dns_cleanups: 0,
            provider_cooldowns: Vec::new(),
            runtime_issues: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct ListenerStatus {
    pub http: Option<String>,
    pub https: Option<String>,
    pub dns: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RouteResolutionState {
    #[default]
    Waiting,
    Resolving,
    Ready,
    Mismatch,
    Unavailable,
}

#[derive(Clone, Debug, Serialize)]
pub struct RouteStatus {
    pub domain: String,
    pub upstream: String,
    pub resolved_addresses: Vec<String>,
    pub resolved_ipv4s: Vec<String>,
    pub expected_ipv4: Option<String>,
    pub certificate_id: String,
    pub resolution_state: RouteResolutionState,
    pub last_resolved_at: Option<String>,
    pub last_online_at: Option<String>,
    pub last_error: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CertificateAvailability {
    #[default]
    Unavailable,
    Valid,
    Expired,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CertificateOperation {
    #[default]
    Idle,
    Queued,
    Issuing,
    Renewing,
    Replacing,
    WaitingRetry,
    Suspended,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CertificateStage {
    Account,
    Ordering,
    ProvisioningChallenge,
    Validating,
    Finalizing,
    Downloading,
    Installing,
    Cleanup,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FailureSource {
    Configuration,
    Network,
    AcmeAccount,
    AcmeOrder,
    AcmeAuthorization,
    AcmeFinalize,
    CertificateDownload,
    CertificateValidation,
    Storage,
    DnsProvider,
    DnsPropagation,
    DnsCleanup,
    Runtime,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FailureKind {
    Transient,
    RateLimited,
    UserActionRequired,
    Permanent,
    Interrupted,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct CertificateFailure {
    pub source: FailureSource,
    pub kind: FailureKind,
    pub code: String,
    pub message: String,
    pub occurred_at: String,
    pub retry_at: Option<String>,
    pub authority: Option<CertificateAuthorityKind>,
    pub challenge: Option<String>,
    pub dns_provider: Option<DnsProviderKind>,
    pub acme_problem_type: Option<String>,
    pub http_status: Option<u16>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ProviderCooldownStatus {
    pub authority: CertificateAuthorityKind,
    pub until: String,
    pub reason: CertificateFailure,
}

#[derive(Clone, Debug, Serialize)]
pub struct RuntimeIssue {
    pub code: String,
    pub message: String,
    pub occurred_at: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct CertificateStatus {
    pub id: String,
    pub domains: Vec<String>,
    pub authority: CertificateAuthorityKind,
    pub challenge: String,
    pub active_authority: Option<CertificateAuthorityKind>,
    pub active_challenge: Option<String>,
    pub availability: CertificateAvailability,
    pub operation: CertificateOperation,
    pub stage: Option<CertificateStage>,
    pub not_before: Option<String>,
    pub not_after: Option<String>,
    pub next_renewal_at: Option<String>,
    pub next_attempt_at: Option<String>,
    pub last_attempt_at: Option<String>,
    pub failure: Option<CertificateFailure>,
}

impl CertificateStatus {
    pub fn pending(
        id: String,
        domains: Vec<String>,
        authority: CertificateAuthorityKind,
        challenge: String,
    ) -> Self {
        Self {
            id,
            domains,
            authority,
            challenge,
            active_authority: None,
            active_challenge: None,
            availability: CertificateAvailability::Unavailable,
            operation: CertificateOperation::Queued,
            stage: None,
            not_before: None,
            not_after: None,
            next_renewal_at: None,
            next_attempt_at: None,
            last_attempt_at: None,
            failure: None,
        }
    }
}
