use std::{
    collections::BTreeMap,
    net::SocketAddr,
    str::FromStr,
    sync::{
        Arc,
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

use super::{
    config::{
        ParsedUpstream, UpstreamScheme, ValidatedGatewayConfig, normalize_domain, socket_host_port,
    },
    status::RouteStatus,
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
    addresses: Arc<[SocketAddr]>,
    next_address: AtomicUsize,
}

impl RuntimeRoute {
    fn address(&self) -> SocketAddr {
        let index = self.next_address.fetch_add(1, Ordering::Relaxed);
        self.addresses[index % self.addresses.len()]
    }

    pub fn status(&self) -> RouteStatus {
        RouteStatus {
            domain: self.domain.clone(),
            upstream: self.upstream.original_url.clone(),
            resolved_addresses: self.addresses.iter().map(ToString::to_string).collect(),
            certificate_id: self.certificate_id.clone(),
        }
    }
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
}

pub async fn resolve_route_table(
    config: &ValidatedGatewayConfig,
) -> Result<Arc<RouteTable>, String> {
    let mut routes = BTreeMap::new();
    for route in config.routes.values() {
        let target = socket_host_port(&route.upstream.host, route.upstream.port);
        let mut addresses = tokio::net::lookup_host(&target)
            .await
            .map_err(|error| format!("failed to resolve upstream {target}: {error}"))?
            .collect::<Vec<_>>();
        addresses.sort_unstable();
        addresses.dedup();
        if addresses.is_empty() {
            return Err(format!("upstream {target} did not resolve to any address"));
        }
        routes.insert(
            route.domain.clone(),
            Arc::new(RuntimeRoute {
                domain: route.domain.clone(),
                certificate_id: route.certificate_id.clone(),
                upstream: route.upstream.clone(),
                addresses: addresses.into(),
                next_address: AtomicUsize::new(0),
            }),
        );
    }
    Ok(Arc::new(RouteTable { routes }))
}

#[derive(Default)]
pub struct RequestContext {
    route: Option<Arc<RuntimeRoute>>,
    host: Option<String>,
    is_tls: bool,
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
            respond_text(
                session,
                StatusCode::MISDIRECTED_REQUEST,
                "unknown gateway host",
            )
            .await?;
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
        Ok(Box::new(build_upstream_peer(route)))
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

fn build_upstream_peer(route: &RuntimeRoute) -> HttpPeer {
    let tls = route.upstream.scheme == UpstreamScheme::Https;
    let sni = route
        .upstream
        .tls_server_name
        .as_deref()
        .unwrap_or_default()
        .to_string();
    let mut peer = HttpPeer::new(route.address(), tls, sni);
    peer.options.connection_timeout = Some(Duration::from_secs(5));
    peer.options.total_connection_timeout = Some(Duration::from_secs(10));
    peer.options.idle_timeout = Some(Duration::from_secs(60));
    peer.options.alpn = if tls { ALPN::H2H1 } else { ALPN::H1 };
    peer
}

fn request_host(request: &RequestHeader) -> Result<String, String> {
    let host = request
        .headers
        .get(header::HOST)
        .ok_or_else(|| "request does not contain Host".to_string())?
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
            },
            addresses: Arc::from(["10.0.0.10:8443".parse().unwrap()]),
            next_address: AtomicUsize::new(0),
        };

        let peer = build_upstream_peer(&route);
        assert!(peer.is_tls());
        assert_eq!(peer.sni, "internal.example.com");
        assert!(peer.options.verify_cert);
        assert!(peer.options.verify_hostname);
        assert_eq!(peer.options.alpn, ALPN::H2H1);
    }
}
