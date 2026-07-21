use serde::Serialize;

use super::config::{CertificateAuthorityKind, GATEWAY_SCHEMA_VERSION};

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
    pub config_generation: u64,
    pub listeners: ListenerStatus,
    pub routes: Vec<RouteStatus>,
    pub certificates: Vec<CertificateStatus>,
    pub pending_dns_cleanups: usize,
    pub last_error: Option<String>,
}

impl Default for GatewayStatusSnapshot {
    fn default() -> Self {
        Self {
            schema_version: GATEWAY_SCHEMA_VERSION,
            state: GatewayState::Stopped,
            config_generation: 0,
            listeners: ListenerStatus::default(),
            routes: Vec::new(),
            certificates: Vec::new(),
            pending_dns_cleanups: 0,
            last_error: None,
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

#[derive(Clone, Copy, Debug, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CertificateState {
    #[default]
    Pending,
    Issuing,
    Active,
    Renewing,
    Degraded,
    Failed,
}

#[derive(Clone, Copy, Debug, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CertificateServingMode {
    #[default]
    PendingHttps,
    Https,
    HttpOnly,
}

#[derive(Clone, Debug, Serialize)]
pub struct CertificateStatus {
    pub id: String,
    pub domains: Vec<String>,
    pub authority: CertificateAuthorityKind,
    pub challenge: String,
    pub active_authority: Option<CertificateAuthorityKind>,
    pub active_challenge: Option<String>,
    pub state: CertificateState,
    pub serving_mode: CertificateServingMode,
    pub not_before: Option<String>,
    pub not_after: Option<String>,
    pub next_renewal_at: Option<String>,
    pub last_attempt_at: Option<String>,
    pub last_error: Option<String>,
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
            state: CertificateState::Pending,
            serving_mode: CertificateServingMode::PendingHttps,
            not_before: None,
            not_after: None,
            next_renewal_at: None,
            last_attempt_at: None,
            last_error: None,
        }
    }
}
