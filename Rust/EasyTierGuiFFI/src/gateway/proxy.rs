use std::{
    collections::BTreeMap,
    net::SocketAddr,
    str::FromStr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use arc_swap::ArcSwap;
use async_trait::async_trait;
use bytes::Bytes;
use dashmap::DashMap;
use http::{Method, StatusCode, Uri, header};
use pingora::{
    Error, ErrorType, Result,
    http::{RequestHeader, ResponseHeader},
    protocols::ALPN,
    proxy::{ProxyHttp, Session},
    upstreams::peer::HttpPeer,
};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use tokio::{
    sync::{Mutex as AsyncMutex, watch},
    task::JoinHandle,
    time::sleep,
};

use super::{
    config::{
        ParsedUpstream, UpstreamAvailability, UpstreamScheme, ValidatedGatewayConfig,
        normalize_domain, socket_host_port,
    },
    status::{RouteResolutionState, RouteStatus},
    tls::{DynamicCertificateStore, SniConnectionInfo},
};

const HTTP01_PREFIX: &str = "/.well-known/acme-challenge/";

#[derive(Clone, Debug, Hash, PartialEq, Eq)]
struct Http01Key {
    domain: String,
    token: String,
}

pub struct Http01ChallengeStore {
    values: DashMap<Http01Key, String>,
}

impl Http01ChallengeStore {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            values: DashMap::new(),
        })
    }

    pub fn insert(&self, domain: String, token: String, key_authorization: String) {
        self.values
            .insert(Http01Key { domain, token }, key_authorization);
    }

    pub fn remove(&self, domain: &str, token: &str) {
        self.values.remove(&Http01Key {
            domain: domain.to_string(),
            token: token.to_string(),
        });
    }

    pub(crate) fn get(&self, domain: &str, token: &str) -> Option<String> {
        self.values
            .get(&Http01Key {
                domain: domain.to_string(),
                token: token.to_string(),
            })
            .map(|entry| entry.value().clone())
    }
}

pub struct RuntimeRoute {
    pub domain: String,
    pub certificate_id: String,
    pub upstream: ParsedUpstream,
    addresses: ArcSwap<Vec<SocketAddr>>,
    resolution: Mutex<RouteResolution>,
    resolution_lock: AsyncMutex<()>,
    next_address: AtomicUsize,
}

#[derive(Default)]
struct RouteResolution {
    state: RouteResolutionState,
    last_resolved_at: Option<String>,
    last_online_at: Option<String>,
    last_error: Option<String>,
}

impl RuntimeRoute {
    fn address(&self) -> Option<SocketAddr> {
        let addresses = self.addresses.load();
        if addresses.is_empty() {
            return None;
        }
        let index = self.next_address.fetch_add(1, Ordering::Relaxed);
        Some(addresses[index % addresses.len()])
    }

    async fn address_for_request(&self) -> Option<SocketAddr> {
        if self.upstream.availability != UpstreamAvailability::Ready {
            return None;
        }
        if let Some(address) = self.address() {
            return Some(address);
        }

        let _guard = self.resolution_lock.lock().await;
        if let Some(address) = self.address() {
            return Some(address);
        }

        self.resolve_locked().await;
        self.address()
    }

    pub fn status(&self) -> RouteStatus {
        let addresses = self.addresses.load();
        let resolution = self.resolution.lock().unwrap();
        RouteStatus {
            domain: self.domain.clone(),
            upstream: self.upstream.original_url.clone(),
            resolved_addresses: addresses.iter().map(ToString::to_string).collect(),
            resolved_ipv4s: addresses
                .iter()
                .map(|address| address.ip().to_string())
                .collect(),
            expected_ipv4: self
                .upstream
                .expected_ipv4
                .map(|address| address.to_string()),
            certificate_id: self.certificate_id.clone(),
            resolution_state: resolution.state,
            last_resolved_at: resolution.last_resolved_at.clone(),
            last_online_at: resolution.last_online_at.clone(),
            last_error: resolution.last_error.clone(),
        }
    }

    async fn resolve(&self) -> bool {
        let _guard = self.resolution_lock.lock().await;
        self.resolve_locked().await
    }

    async fn resolve_locked(&self) -> bool {
        match self.upstream.availability {
            UpstreamAvailability::Waiting => {
                self.set_state(RouteResolutionState::Waiting, None);
                return false;
            }
            UpstreamAvailability::Unavailable => {
                self.set_state(
                    RouteResolutionState::Unavailable,
                    Some("target is unavailable".to_string()),
                );
                return false;
            }
            UpstreamAvailability::Ready => {}
        }
        let should_record_online = {
            let mut resolution = self.resolution.lock().unwrap();
            let should_record_online = resolution.state != RouteResolutionState::Ready;
            if self.addresses.load().is_empty() {
                resolution.state = RouteResolutionState::Resolving;
                resolution.last_error = None;
            }
            should_record_online
        };

        let target = socket_host_port(&self.upstream.host, self.upstream.port);
        let result = tokio::net::lookup_host(&target).await.map(|addresses| {
            let addresses = addresses.collect::<Vec<_>>();
            let has_mismatch = self.upstream.expected_ipv4.is_some_and(|expected| {
                addresses.iter().any(|address| match address.ip() {
                    std::net::IpAddr::V4(ipv4) => ipv4 != expected,
                    std::net::IpAddr::V6(_) => false,
                })
            });
            let mut addresses = addresses
                .into_iter()
                .filter(
                    |address| match (self.upstream.allowed_ipv4_cidr, address.ip()) {
                        (Some(cidr), std::net::IpAddr::V4(ipv4)) => cidr.contains(ipv4),
                        (Some(_), std::net::IpAddr::V6(_)) => false,
                        (None, _) => true,
                    },
                )
                .collect::<Vec<_>>();
            addresses.sort_unstable();
            addresses.dedup();
            (addresses, has_mismatch)
        });

        match result {
            Ok((_, true)) => {
                self.set_state(
                    RouteResolutionState::Mismatch,
                    Some("upstream DNS did not resolve exclusively to expected_ipv4".to_string()),
                );
                false
            }
            Ok((addresses, false)) if !addresses.is_empty() => {
                self.addresses.store(Arc::new(addresses));
                let mut resolution = self.resolution.lock().unwrap();
                let resolved_at = current_timestamp();
                resolution.state = RouteResolutionState::Ready;
                resolution.last_resolved_at = Some(resolved_at.clone());
                if should_record_online {
                    resolution.last_online_at = Some(resolved_at);
                }
                resolution.last_error = None;
                true
            }
            Ok(_) => {
                self.mark_resolution_failure(format!(
                    "upstream {target} did not resolve inside the allowed EasyTier network"
                ));
                false
            }
            Err(error) => {
                self.mark_resolution_failure(format!(
                    "failed to resolve upstream {target}: {error}"
                ));
                false
            }
        }
    }

    fn mark_resolution_failure(&self, error: String) {
        let state = if self.resolution.lock().unwrap().last_online_at.is_none() {
            RouteResolutionState::Resolving
        } else {
            RouteResolutionState::Unavailable
        };
        self.set_state(state, Some(error));
    }

    #[cfg(test)]
    fn mark_unavailable(&self, error: String) {
        self.set_state(RouteResolutionState::Unavailable, Some(error));
    }

    fn set_state(&self, state: RouteResolutionState, error: Option<String>) {
        self.addresses.store(Arc::new(Vec::new()));
        let mut resolution = self.resolution.lock().unwrap();
        resolution.state = state;
        resolution.last_error = error;
    }
}

fn current_timestamp() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| OffsetDateTime::now_utc().unix_timestamp().to_string())
}

#[derive(Default)]
pub struct RouteTable {
    routes: BTreeMap<String, Arc<RuntimeRoute>>,
}

impl RouteTable {
    pub fn get(&self, domain: &str) -> Option<Arc<RuntimeRoute>> {
        self.routes.get(domain).cloned()
    }

    pub fn statuses(&self) -> Vec<RouteStatus> {
        self.routes.values().map(|route| route.status()).collect()
    }

    fn all_routes(&self) -> Vec<Arc<RuntimeRoute>> {
        self.routes.values().cloned().collect()
    }
}

pub fn build_route_table(config: &ValidatedGatewayConfig) -> Arc<RouteTable> {
    let mut routes = BTreeMap::new();
    for route in config.routes.values() {
        routes.insert(
            route.domain.clone(),
            Arc::new(RuntimeRoute {
                domain: route.domain.clone(),
                certificate_id: route.certificate_id.clone(),
                upstream: route.upstream.clone(),
                addresses: ArcSwap::from_pointee(Vec::new()),
                resolution: Mutex::new(RouteResolution {
                    state: match route.upstream.availability {
                        UpstreamAvailability::Waiting => RouteResolutionState::Waiting,
                        UpstreamAvailability::Unavailable => RouteResolutionState::Unavailable,
                        UpstreamAvailability::Ready => RouteResolutionState::Resolving,
                    },
                    ..RouteResolution::default()
                }),
                resolution_lock: AsyncMutex::new(()),
                next_address: AtomicUsize::new(0),
            }),
        );
    }
    Arc::new(RouteTable { routes })
}

pub fn spawn_route_resolvers(
    route_table: Arc<RouteTable>,
    shutdown: watch::Receiver<bool>,
) -> Vec<JoinHandle<()>> {
    route_table
        .all_routes()
        .into_iter()
        .map(|route| {
            let mut shutdown = shutdown.clone();
            tokio::spawn(async move {
                loop {
                    let resolved = route.resolve().await;
                    let delay = if resolved {
                        Duration::from_secs(30)
                    } else {
                        Duration::from_secs(5)
                    };
                    tokio::select! {
                        changed = shutdown.changed() => {
                            if changed.is_err() || *shutdown.borrow() { return; }
                        }
                        _ = sleep(delay) => {}
                    }
                }
            })
        })
        .collect()
}

#[derive(Default)]
pub struct RequestContext {
    route: Option<Arc<RuntimeRoute>>,
    host: Option<String>,
    is_tls: bool,
    upstream_address: Option<SocketAddr>,
}

pub struct GatewayProxy {
    routes: Arc<SharedRouteTable>,
    certificates: Arc<DynamicCertificateStore>,
    challenges: Arc<Http01ChallengeStore>,
}

pub struct SharedRouteTable {
    current: ArcSwap<RouteTable>,
}

impl SharedRouteTable {
    pub fn new(route_table: Arc<RouteTable>) -> Arc<Self> {
        Arc::new(Self {
            current: ArcSwap::from(route_table),
        })
    }

    pub fn replace(&self, route_table: Arc<RouteTable>) {
        self.current.store(route_table);
    }

    pub fn statuses(&self) -> Vec<RouteStatus> {
        self.current.load().statuses()
    }

    pub fn snapshot(&self) -> Arc<RouteTable> {
        self.current.load_full()
    }

    #[cfg(test)]
    pub(super) fn mark_unavailable_for_test(&self, domain: &str) {
        self.get(domain)
            .expect("test route must exist")
            .mark_unavailable("target network stopped".to_string());
    }

    fn get(&self, domain: &str) -> Option<Arc<RuntimeRoute>> {
        self.current.load().get(domain)
    }
}

impl GatewayProxy {
    pub fn new(
        routes: Arc<SharedRouteTable>,
        certificates: Arc<DynamicCertificateStore>,
        challenges: Arc<Http01ChallengeStore>,
    ) -> Self {
        Self {
            routes,
            certificates,
            challenges,
        }
    }
}

#[async_trait]
impl ProxyHttp for GatewayProxy {
    type CTX = RequestContext;

    fn new_ctx(&self) -> Self::CTX {
        RequestContext::default()
    }

    async fn request_filter(&self, session: &mut Session, context: &mut Self::CTX) -> Result<bool> {
        let host = match request_host(session.req_header()) {
            Ok(host) => host,
            Err(_) => {
                respond_text(
                    session,
                    StatusCode::MISDIRECTED_REQUEST,
                    "unknown gateway host",
                )
                .await?;
                return Ok(true);
            }
        };
        context.host = Some(host.clone());

        if let Some(token) = http01_token(session.req_header().uri.path()) {
            if session.req_header().method != Method::GET {
                respond_text(
                    session,
                    StatusCode::METHOD_NOT_ALLOWED,
                    "method not allowed",
                )
                .await?;
                return Ok(true);
            }
            let Some(key_authorization) = self.challenges.get(&host, token) else {
                respond_text(session, StatusCode::NOT_FOUND, "challenge not found").await?;
                return Ok(true);
            };
            respond_with_headers(
                session,
                StatusCode::OK,
                key_authorization,
                &[
                    ("Content-Type", "text/plain; charset=utf-8"),
                    ("Cache-Control", "no-store"),
                ],
            )
            .await?;
            return Ok(true);
        }

        let route = self.routes.get(&host);
        let Some(route) = route else {
            respond_text(session, StatusCode::NOT_FOUND, "not found").await?;
            return Ok(true);
        };

        let sni = request_sni(session);
        context.is_tls = sni.is_some();
        if let Some(sni) = sni {
            if sni != host {
                respond_text(
                    session,
                    StatusCode::MISDIRECTED_REQUEST,
                    "TLS SNI and HTTP Host do not match",
                )
                .await?;
                return Ok(true);
            }
            let Some(address) = route.address_for_request().await else {
                let (message, retry_after) = match route.status().resolution_state {
                    RouteResolutionState::Waiting | RouteResolutionState::Resolving => {
                        ("Target is starting", "2")
                    }
                    RouteResolutionState::Mismatch => ("Target DNS mismatch", "5"),
                    _ => ("Target is unavailable", "5"),
                };
                respond_with_headers(
                    session,
                    StatusCode::SERVICE_UNAVAILABLE,
                    message.to_string(),
                    &[("Retry-After", retry_after)],
                )
                .await?;
                return Ok(true);
            };
            context.upstream_address = Some(address);
            context.route = Some(route);
            return Ok(false);
        }

        if !self.certificates.has_certificate_for_domain(&host) {
            respond_with_headers(
                session,
                StatusCode::SERVICE_UNAVAILABLE,
                "TLS certificate is not ready".to_string(),
                &[("Retry-After", "30")],
            )
            .await?;
            return Ok(true);
        }

        let location = https_redirect_location(&host, &session.req_header().uri);
        respond_with_headers(
            session,
            StatusCode::PERMANENT_REDIRECT,
            String::new(),
            &[("Location", &location)],
        )
        .await?;
        Ok(true)
    }

    async fn upstream_peer(
        &self,
        _session: &mut Session,
        context: &mut Self::CTX,
    ) -> Result<Box<HttpPeer>> {
        let route = context.route.as_ref().ok_or_else(|| {
            Error::explain(
                ErrorType::InternalError,
                "gateway route was not selected before upstream lookup",
            )
        })?;
        let address = context.upstream_address.ok_or_else(|| {
            Error::explain(
                ErrorType::ConnectError,
                "gateway upstream address is unavailable",
            )
        })?;
        Ok(Box::new(build_upstream_peer(route, address)))
    }

    async fn upstream_request_filter(
        &self,
        _session: &mut Session,
        upstream_request: &mut RequestHeader,
        context: &mut Self::CTX,
    ) -> Result<()> {
        let route = context.route.as_ref().ok_or_else(|| {
            Error::explain(
                ErrorType::InternalError,
                "gateway route was not selected before request filtering",
            )
        })?;
        if let Some(host_header) = route.upstream.host_header.as_deref() {
            upstream_request.insert_header(header::HOST, host_header)?;
        }
        upstream_request.insert_header(
            "X-Forwarded-Proto",
            if context.is_tls { "https" } else { "http" },
        )?;
        if let Some(host) = context.host.as_deref() {
            upstream_request.insert_header("X-Forwarded-Host", host)?;
        }
        Ok(())
    }

    async fn response_filter(
        &self,
        _session: &mut Session,
        upstream_response: &mut ResponseHeader,
        _context: &mut Self::CTX,
    ) -> Result<()> {
        upstream_response.remove_header("alt-svc");
        Ok(())
    }
}

fn build_upstream_peer(route: &RuntimeRoute, address: SocketAddr) -> HttpPeer {
    let tls = route.upstream.scheme == UpstreamScheme::Https;
    let sni = route
        .upstream
        .tls_server_name
        .as_deref()
        .unwrap_or_default()
        .to_string();
    let mut peer = HttpPeer::new(address, tls, sni);
    peer.options.connection_timeout = Some(Duration::from_secs(5));
    peer.options.total_connection_timeout = Some(Duration::from_secs(10));
    peer.options.idle_timeout = Some(Duration::from_secs(60));
    peer.options.alpn = if tls { ALPN::H2H1 } else { ALPN::H1 };
    peer
}

fn request_host(request: &RequestHeader) -> Result<String, String> {
    // HTTP/2 carries :authority in the URI and may omit the Host header.
    if let Some(authority) = request.uri.authority() {
        return normalize_domain(authority.host());
    }

    let host = request
        .headers
        .get(header::HOST)
        .ok_or_else(|| "request does not contain an authority or Host".to_string())?
        .to_str()
        .map_err(|error| format!("request Host is not valid text: {error}"))?;
    let authority = http::uri::Authority::from_str(host)
        .map_err(|error| format!("request Host is invalid: {error}"))?;
    normalize_domain(authority.host())
}

fn request_sni(session: &Session) -> Option<String> {
    session
        .as_downstream()
        .digest()?
        .ssl_digest
        .as_ref()?
        .extension
        .get::<SniConnectionInfo>()
        .map(|info| info.server_name.clone())
}

fn http01_token(path: &str) -> Option<&str> {
    let token = path.strip_prefix(HTTP01_PREFIX)?;
    if token.is_empty()
        || token.contains('/')
        || !token
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return None;
    }
    Some(token)
}

fn https_redirect_location(host: &str, uri: &Uri) -> String {
    let path_and_query = uri
        .path_and_query()
        .map(|value| value.as_str())
        .unwrap_or("/");
    format!("https://{host}{path_and_query}")
}

async fn respond_text(session: &mut Session, status: StatusCode, body: &'static str) -> Result<()> {
    respond_with_headers(
        session,
        status,
        body.to_string(),
        &[("Content-Type", "text/plain; charset=utf-8")],
    )
    .await
}

async fn respond_with_headers(
    session: &mut Session,
    status: StatusCode,
    body: String,
    headers: &[(&'static str, &str)],
) -> Result<()> {
    let mut response = ResponseHeader::build(status, Some(headers.len() + 1))?;
    response.insert_header("Content-Length", body.len().to_string())?;
    for (name, value) in headers {
        response.insert_header(*name, *value)?;
    }
    let end_of_stream = body.is_empty();
    session
        .write_response_header(Box::new(response), end_of_stream)
        .await?;
    if !body.is_empty() {
        session
            .write_response_body(Some(Bytes::from(body)), true)
            .await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_host_uses_http1_host_header() {
        let mut request = RequestHeader::build(Method::GET, b"/", Some(1)).unwrap();
        request
            .insert_header(header::HOST, "App.Example.com:8443")
            .unwrap();

        assert_eq!(request_host(&request).unwrap(), "app.example.com");
    }

    #[test]
    fn request_host_uses_http2_authority_before_host_header() {
        let mut request = RequestHeader::build_no_case(Method::GET, b"/path", Some(1)).unwrap();
        request.uri = "https://H2.Example.com:443/path".parse().unwrap();
        request.set_version(http::Version::HTTP_2);
        request
            .insert_header(header::HOST, "ignored.example.com")
            .unwrap();

        assert_eq!(request_host(&request).unwrap(), "h2.example.com");
    }

    #[test]
    fn request_host_rejects_requests_without_authority_or_host() {
        let request = RequestHeader::build(Method::GET, b"/", None).unwrap();

        assert_eq!(
            request_host(&request).unwrap_err(),
            "request does not contain an authority or Host"
        );
    }

    #[test]
    fn parses_http01_token_strictly() {
        assert_eq!(
            http01_token("/.well-known/acme-challenge/abc_DEF-123"),
            Some("abc_DEF-123")
        );
        assert_eq!(http01_token("/.well-known/acme-challenge/"), None);
        assert_eq!(http01_token("/.well-known/acme-challenge/abc/other"), None);
    }

    #[test]
    fn redirect_preserves_path_and_query() {
        let uri: Uri = "/hello?q=1".parse().unwrap();
        assert_eq!(
            https_redirect_location("app.example.com", &uri),
            "https://app.example.com/hello?q=1"
        );
    }

    #[test]
    fn http01_challenge_store_is_scoped_by_domain_and_token() {
        let challenges = Http01ChallengeStore::new();
        challenges.insert(
            "app.example.com".to_string(),
            "token-one".to_string(),
            "authorization".to_string(),
        );
        assert_eq!(
            challenges.get("app.example.com", "token-one").as_deref(),
            Some("authorization")
        );
        assert!(challenges.get("other.example.com", "token-one").is_none());
        challenges.remove("app.example.com", "token-one");
        assert!(challenges.get("app.example.com", "token-one").is_none());
    }

    #[test]
    fn https_upstream_peer_keeps_certificate_and_hostname_verification_enabled() {
        let route = RuntimeRoute {
            domain: "app.example.com".to_string(),
            certificate_id: "app-cert".to_string(),
            upstream: ParsedUpstream {
                original_url: "https://10.0.0.10:8443".to_string(),
                scheme: UpstreamScheme::Https,
                host: "10.0.0.10".to_string(),
                port: 8443,
                host_header: None,
                tls_server_name: Some("internal.example.com".to_string()),
                allowed_ipv4_cidr: None,
                availability: UpstreamAvailability::Ready,
                expected_ipv4: None,
            },
            addresses: ArcSwap::from_pointee(vec!["10.0.0.10:8443".parse().unwrap()]),
            resolution: Mutex::new(RouteResolution::default()),
            resolution_lock: AsyncMutex::new(()),
            next_address: AtomicUsize::new(0),
        };

        let peer = build_upstream_peer(&route, "10.0.0.10:8443".parse().unwrap());
        assert!(peer.is_tls());
        assert_eq!(peer.sni, "internal.example.com");
        assert!(peer.options.verify_cert);
        assert!(peer.options.verify_hostname);
        assert_eq!(peer.options.alpn, ALPN::H2H1);
    }

    #[test]
    fn request_resolves_route_before_background_resolver_has_completed() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let route = unresolved_loopback_route();

            assert_eq!(
                route.address_for_request().await,
                Some("127.0.0.1:3000".parse().unwrap())
            );
            assert_eq!(route.status().resolution_state, RouteResolutionState::Ready);
            assert!(route.status().last_online_at.is_some());

            route.resolution.lock().unwrap().last_online_at = Some("first-online".to_string());
            assert!(route.resolve().await);
            assert_eq!(
                route.status().last_online_at.as_deref(),
                Some("first-online")
            );
        });
    }

    #[test]
    fn request_retries_route_after_target_network_recovers() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let route = unresolved_loopback_route();
            route.resolution.lock().unwrap().last_online_at = Some("first-online".to_string());
            route.mark_unavailable("target network stopped".to_string());
            assert_eq!(
                route.status().resolution_state,
                RouteResolutionState::Unavailable
            );
            assert_eq!(
                route.status().last_online_at.as_deref(),
                Some("first-online")
            );

            assert_eq!(
                route.address_for_request().await,
                Some("127.0.0.1:3000".parse().unwrap())
            );
            assert_eq!(route.status().resolution_state, RouteResolutionState::Ready);
            assert_ne!(
                route.status().last_online_at.as_deref(),
                Some("first-online")
            );
        });
    }

    #[test]
    fn waiting_route_does_not_resolve_or_reuse_addresses() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let mut route = unresolved_loopback_route();
            route.upstream.availability = UpstreamAvailability::Waiting;
            route
                .addresses
                .store(Arc::new(vec!["127.0.0.1:3000".parse().unwrap()]));

            assert_eq!(route.address_for_request().await, None);
        });
    }

    #[test]
    fn expected_ipv4_rejects_a_same_cidr_wrong_answer() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let mut route = unresolved_loopback_route();
            route.upstream.host = "localhost".to_string();
            route.upstream.expected_ipv4 = Some("127.0.0.2".parse().unwrap());

            assert_eq!(route.address_for_request().await, None);
            assert_eq!(
                route.status().resolution_state,
                RouteResolutionState::Mismatch
            );
            assert!(route.status().resolved_addresses.is_empty());
        });
    }

    #[test]
    fn initial_lookup_failure_remains_resolving() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let mut route = unresolved_loopback_route();
            route.upstream.host = "invalid..hostname".to_string();

            assert_eq!(route.address_for_request().await, None);
            assert_eq!(
                route.status().resolution_state,
                RouteResolutionState::Resolving
            );
        });
    }

    fn unresolved_loopback_route() -> RuntimeRoute {
        RuntimeRoute {
            domain: "app.example.com".to_string(),
            certificate_id: "app-cert".to_string(),
            upstream: ParsedUpstream {
                original_url: "http://127.0.0.1:3000".to_string(),
                scheme: UpstreamScheme::Http,
                host: "127.0.0.1".to_string(),
                port: 3000,
                host_header: None,
                tls_server_name: None,
                allowed_ipv4_cidr: None,
                availability: UpstreamAvailability::Ready,
                expected_ipv4: None,
            },
            addresses: ArcSwap::from_pointee(Vec::new()),
            resolution: Mutex::new(RouteResolution::default()),
            resolution_lock: AsyncMutex::new(()),
            next_address: AtomicUsize::new(0),
        }
    }
}
