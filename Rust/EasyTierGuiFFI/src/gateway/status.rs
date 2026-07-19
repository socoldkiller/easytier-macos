use serde::Serialize;

use super::config::GATEWAY_SCHEMA_VERSION;

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
    Resolving,
    Ready,
    Unavailable,
}

#[derive(Clone, Debug, Serialize)]
pub struct RouteStatus {
    pub domain: String,
    pub upstream: String,
    pub resolved_addresses: Vec<String>,
    pub certificate_id: String,
    pub resolution_state: RouteResolutionState,
    pub last_resolved_at: Option<String>,
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

#[derive(Clone, Debug, Serialize)]
pub struct CertificateStatus {
    pub id: String,
    pub domains: Vec<String>,
    pub challenge: String,
    pub state: CertificateState,
    pub not_before: Option<String>,
    pub not_after: Option<String>,
    pub next_renewal_at: Option<String>,
    pub last_attempt_at: Option<String>,
    pub last_error: Option<String>,
}

impl CertificateStatus {
    pub fn pending(id: String, domains: Vec<String>, challenge: String) -> Self {
        Self {
            id,
            domains,
            challenge,
            state: CertificateState::Pending,
            not_before: None,
            not_after: None,
            next_renewal_at: None,
            last_attempt_at: None,
            last_error: None,
        }
    }
}
