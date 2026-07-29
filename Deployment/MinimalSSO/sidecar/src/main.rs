use std::{
    collections::HashMap,
    env,
    net::SocketAddr,
    sync::Arc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, anyhow};
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Query, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{Html, IntoResponse, Redirect, Response},
    routing::{get, post},
};
use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use hmac::{Hmac, Mac};
use openidconnect::{
    AccessTokenHash, AdditionalClaims, AuthorizationCode, Client, ClientId, ClientSecret,
    CsrfToken, EmptyExtraTokenFields, EndpointMaybeSet, EndpointNotSet, EndpointSet, IdTokenFields,
    IssuerUrl, Nonce, OAuth2TokenResponse, PkceCodeChallenge, PkceCodeVerifier, RedirectUrl, Scope,
    StandardErrorResponse, StandardTokenResponse, TokenResponse,
    core::{
        CoreAuthDisplay, CoreAuthPrompt, CoreAuthenticationFlow, CoreErrorResponseType,
        CoreGenderClaim, CoreJsonWebKey, CoreJweContentEncryptionAlgorithm,
        CoreJwsSigningAlgorithm, CoreProviderMetadata, CoreRevocableToken,
        CoreRevocationErrorResponse, CoreTokenIntrospectionResponse, CoreTokenType,
    },
};
use rand::{RngCore, rngs::OsRng};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use tokio::sync::Mutex;
use tracing_subscriber::EnvFilter;
use url::Url;

const FLOW_COOKIE: &str = "easytier_native_flow";
const FLOW_LIFETIME: Duration = Duration::from_secs(5 * 60);
const TICKET_LIFETIME_SECONDS: u64 = 60;
const DEFAULT_SCOPES: [&str; 2] = ["openid", "profile"];

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct JsonAdditionalClaims {
    #[serde(flatten)]
    claims: HashMap<String, serde_json::Value>,
}

impl AdditionalClaims for JsonAdditionalClaims {}

type AppIdTokenFields = IdTokenFields<
    JsonAdditionalClaims,
    EmptyExtraTokenFields,
    CoreGenderClaim,
    CoreJweContentEncryptionAlgorithm,
    CoreJwsSigningAlgorithm,
>;
type AppTokenResponse = StandardTokenResponse<AppIdTokenFields, CoreTokenType>;
type AppClient<
    HasAuthUrl = EndpointNotSet,
    HasDeviceAuthUrl = EndpointNotSet,
    HasIntrospectionUrl = EndpointNotSet,
    HasRevocationUrl = EndpointNotSet,
    HasTokenUrl = EndpointNotSet,
    HasUserInfoUrl = EndpointNotSet,
> = Client<
    JsonAdditionalClaims,
    CoreAuthDisplay,
    CoreGenderClaim,
    CoreJweContentEncryptionAlgorithm,
    CoreJsonWebKey,
    CoreAuthPrompt,
    StandardErrorResponse<CoreErrorResponseType>,
    AppTokenResponse,
    CoreTokenIntrospectionResponse,
    CoreRevocableToken,
    CoreRevocationErrorResponse,
    HasAuthUrl,
    HasDeviceAuthUrl,
    HasIntrospectionUrl,
    HasRevocationUrl,
    HasTokenUrl,
    HasUserInfoUrl,
>;
type ConfiguredAppClient = AppClient<
    EndpointSet,
    EndpointNotSet,
    EndpointNotSet,
    EndpointNotSet,
    EndpointMaybeSet,
    EndpointMaybeSet,
>;

#[derive(Clone)]
struct AppState {
    config: Arc<Config>,
    oidc_client: Arc<ConfiguredAppClient>,
    http_client: reqwest::Client,
    flows: Arc<Mutex<HashMap<String, NativeFlow>>>,
    attempts: Arc<Mutex<HashMap<String, OidcAttempt>>>,
}

struct Config {
    listen_address: SocketAddr,
    config_endpoint: String,
    username_claim: String,
    ticket_key: Vec<u8>,
}

struct NativeFlow {
    native_state: String,
    created_at: Instant,
    outcome: FlowOutcome,
}

enum FlowOutcome {
    Pending,
    Authenticated { ticket: String },
    Failed,
}

struct OidcAttempt {
    flow_id: String,
    nonce: String,
    pkce_verifier: String,
    created_at: Instant,
}

#[derive(Deserialize)]
struct NativeLoginQuery {
    native_port: u16,
    native_state: String,
}

#[derive(Deserialize)]
struct OidcCallbackQuery {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
}

#[derive(Serialize)]
struct BootstrapResponse<'a> {
    protocol_version: u8,
    config_endpoint: &'a str,
    login_path: &'static str,
    exchange_path: &'static str,
    console_path: &'static str,
}

#[derive(Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum NativeStatusResponse {
    Pending,
    Authenticated { ticket: String },
    Failed,
}

#[derive(Deserialize)]
struct ExchangeRequest {
    state: String,
    ticket: String,
}

#[derive(Serialize)]
struct ExchangeResponse<'a> {
    username: &'a str,
    config_token: &'a str,
    config_endpoint: &'a str,
    console_path: &'static str,
}

#[derive(Serialize, Deserialize)]
struct TicketPayload {
    purpose: String,
    username: String,
    state: String,
    issued_at: u64,
    expires_at: u64,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();

    let state = build_state().await?;
    let listener = tokio::net::TcpListener::bind(state.config.listen_address).await?;
    tracing::info!(address = %state.config.listen_address, "native SSO sidecar listening");
    axum::serve(listener, router(state)).await?;
    Ok(())
}

fn router(state: AppState) -> Router {
    Router::new()
        .route("/.well-known/easytier-client", get(bootstrap))
        .route("/native/login", get(native_login))
        .route("/native/oidc/start", get(oidc_start))
        .route("/native/oidc/callback", get(oidc_callback))
        .route("/native/status", get(native_status))
        .route("/native/exchange", post(native_exchange))
        .route("/native/console", get(native_console))
        .route("/native/health", get(|| async { StatusCode::NO_CONTENT }))
        .layer(DefaultBodyLimit::max(16 * 1024))
        .with_state(state)
}

async fn build_state() -> anyhow::Result<AppState> {
    let listen_address = required_env("SIDECAR_LISTEN_ADDRESS")?.parse()?;
    let public_origin = parse_public_origin(&required_env("SIDECAR_PUBLIC_ORIGIN")?)?;
    let config_endpoint = validate_config_endpoint(&required_env("SIDECAR_CONFIG_ENDPOINT")?)?;
    let issuer = IssuerUrl::new(required_env("SIDECAR_OIDC_ISSUER")?)?;
    let client_id = ClientId::new(required_env("SIDECAR_OIDC_CLIENT_ID")?);
    let client_secret = ClientSecret::new(required_env("SIDECAR_OIDC_CLIENT_SECRET")?);
    let username_claim = env::var("SIDECAR_OIDC_USERNAME_CLAIM")
        .unwrap_or_else(|_| "preferred_username".to_string());
    if username_claim.trim().is_empty() {
        return Err(anyhow!("SIDECAR_OIDC_USERNAME_CLAIM cannot be empty"));
    }
    let ticket_key = STANDARD
        .decode(required_env("SIDECAR_TICKET_KEY_BASE64")?)
        .context("SIDECAR_TICKET_KEY_BASE64 must be valid Base64")?;
    if ticket_key.len() < 32 {
        return Err(anyhow!(
            "SIDECAR_TICKET_KEY_BASE64 must decode to at least 32 bytes"
        ));
    }

    let http_client = reqwest::ClientBuilder::new()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(30))
        .build()?;
    let metadata = CoreProviderMetadata::discover_async(issuer, &http_client).await?;
    let redirect_url = public_origin.join("/native/oidc/callback")?;
    let oidc_client = AppClient::from_provider_metadata(metadata, client_id, Some(client_secret))
        .set_redirect_uri(RedirectUrl::new(redirect_url.into())?);

    Ok(AppState {
        config: Arc::new(Config {
            listen_address,
            config_endpoint,
            username_claim,
            ticket_key,
        }),
        oidc_client: Arc::new(oidc_client),
        http_client,
        flows: Arc::new(Mutex::new(HashMap::new())),
        attempts: Arc::new(Mutex::new(HashMap::new())),
    })
}

async fn bootstrap(State(state): State<AppState>) -> Response {
    no_store_json(Json(BootstrapResponse {
        protocol_version: 1,
        config_endpoint: &state.config.config_endpoint,
        login_path: "/native/login",
        exchange_path: "/native/exchange",
        console_path: "/native/console",
    }))
}

async fn native_login(
    State(state): State<AppState>,
    Query(query): Query<NativeLoginQuery>,
) -> Response {
    if query.native_port < 1024 || !valid_native_state(&query.native_state) {
        return safe_error(StatusCode::BAD_REQUEST, "Invalid native login parameters.");
    }
    prune_expired(&state).await;
    let flow_id = random_base64url(32);
    let nonce = random_base64url(18);
    let html = coordinator_html(query.native_port, &query.native_state, &nonce);
    state.flows.lock().await.insert(
        flow_id.clone(),
        NativeFlow {
            native_state: query.native_state,
            created_at: Instant::now(),
            outcome: FlowOutcome::Pending,
        },
    );

    let cookie = format!(
        "{FLOW_COOKIE}={flow_id}; Path=/native; Max-Age={}; Secure; HttpOnly; SameSite=Lax",
        FLOW_LIFETIME.as_secs()
    );
    html_response(html, &nonce, Some(cookie))
}

async fn oidc_start(State(state): State<AppState>, headers: HeaderMap) -> Response {
    let Some(flow_id) = flow_cookie(&headers) else {
        return safe_error(
            StatusCode::BAD_REQUEST,
            "The native login session is missing.",
        );
    };
    prune_expired(&state).await;
    if !state.flows.lock().await.contains_key(&flow_id) {
        return safe_error(StatusCode::GONE, "The native login session has expired.");
    }

    let (challenge, verifier) = PkceCodeChallenge::new_random_sha256();
    let mut request = state.oidc_client.authorize_url(
        CoreAuthenticationFlow::AuthorizationCode,
        CsrfToken::new_random,
        Nonce::new_random,
    );
    for scope in DEFAULT_SCOPES {
        request = request.add_scope(Scope::new(scope.to_string()));
    }
    let (url, csrf, nonce) = request.set_pkce_challenge(challenge).url();
    state.attempts.lock().await.insert(
        csrf.secret().clone(),
        OidcAttempt {
            flow_id,
            nonce: nonce.secret().clone(),
            pkce_verifier: verifier.secret().clone(),
            created_at: Instant::now(),
        },
    );
    Redirect::temporary(url.as_str()).into_response()
}

async fn oidc_callback(
    State(state): State<AppState>,
    Query(query): Query<OidcCallbackQuery>,
) -> Response {
    let Some(callback_state) = query.state else {
        return safe_error(StatusCode::BAD_REQUEST, "Missing OIDC state.");
    };
    let Some(attempt) = state.attempts.lock().await.remove(&callback_state) else {
        return safe_error(
            StatusCode::BAD_REQUEST,
            "The OIDC attempt is invalid or expired.",
        );
    };
    if attempt.created_at.elapsed() > FLOW_LIFETIME || query.error.is_some() {
        mark_flow_failed(&state, &attempt.flow_id).await;
        return safe_error(
            StatusCode::UNAUTHORIZED,
            "The identity provider rejected sign-in.",
        );
    }
    let Some(code) = query.code else {
        mark_flow_failed(&state, &attempt.flow_id).await;
        return safe_error(StatusCode::BAD_REQUEST, "Missing authorization code.");
    };

    let username = match exchange_oidc_code(&state, code, &attempt).await {
        Ok(username) => username,
        Err(error) => {
            tracing::warn!(error = %error, "OIDC validation failed");
            mark_flow_failed(&state, &attempt.flow_id).await;
            return safe_error(
                StatusCode::UNAUTHORIZED,
                "OIDC sign-in could not be verified.",
            );
        }
    };

    let mut flows = state.flows.lock().await;
    let Some(flow) = flows.get_mut(&attempt.flow_id) else {
        return safe_error(StatusCode::GONE, "The native login session has expired.");
    };
    let ticket = match issue_ticket(&state.config.ticket_key, &username, &flow.native_state) {
        Ok(ticket) => ticket,
        Err(error) => {
            tracing::error!(error = %error, "failed to issue native ticket");
            flow.outcome = FlowOutcome::Failed;
            return safe_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Sign-in could not be completed.",
            );
        }
    };
    flow.outcome = FlowOutcome::Authenticated { ticket };
    drop(flows);

    // The second OIDC hop establishes easytier-web's own browser session. Casdoor
    // already has a session, so this normally completes without another password prompt.
    Redirect::temporary("/api/v1/auth/oidc/login").into_response()
}

async fn native_status(State(state): State<AppState>, headers: HeaderMap) -> Response {
    let Some(flow_id) = flow_cookie(&headers) else {
        return no_store_json(Json(NativeStatusResponse::Failed));
    };
    prune_expired(&state).await;
    let flows = state.flows.lock().await;
    let response = match flows.get(&flow_id).map(|flow| &flow.outcome) {
        Some(FlowOutcome::Pending) => NativeStatusResponse::Pending,
        Some(FlowOutcome::Authenticated { ticket }) => NativeStatusResponse::Authenticated {
            ticket: ticket.clone(),
        },
        Some(FlowOutcome::Failed) | None => NativeStatusResponse::Failed,
    };
    no_store_json(Json(response))
}

async fn native_exchange(
    State(state): State<AppState>,
    Json(request): Json<ExchangeRequest>,
) -> Response {
    if !valid_native_state(&request.state) {
        return safe_json_error(StatusCode::BAD_REQUEST, "Invalid exchange request.");
    }
    let payload = match verify_ticket(&state.config.ticket_key, &request.ticket) {
        Ok(payload) if payload.state == request.state => payload,
        _ => {
            return safe_json_error(
                StatusCode::UNAUTHORIZED,
                "The login ticket is invalid or expired.",
            );
        }
    };
    no_store_json(Json(ExchangeResponse {
        username: &payload.username,
        config_token: &payload.username,
        config_endpoint: &state.config.config_endpoint,
        console_path: "/native/console",
    }))
}

async fn native_console() -> Response {
    let nonce = random_base64url(18);
    let html = format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>Opening EasyTier Console</title></head><body><p>Opening EasyTier Console...</p><script nonce=\"{nonce}\">const apiHost=btoa(location.origin);localStorage.setItem('apiHost',apiHost);location.replace('/#/h/'+apiHost);</script></body></html>"
    );
    html_response(html, &nonce, None)
}

async fn exchange_oidc_code(
    state: &AppState,
    code: String,
    attempt: &OidcAttempt,
) -> anyhow::Result<String> {
    let token_response = state
        .oidc_client
        .exchange_code(AuthorizationCode::new(code))?
        .set_pkce_verifier(PkceCodeVerifier::new(attempt.pkce_verifier.clone()))
        .request_async(&state.http_client)
        .await
        .map_err(|_| anyhow!("OIDC code exchange failed"))?;
    let id_token = token_response
        .id_token()
        .context("OIDC response has no ID token")?;
    let claims = id_token
        .claims(
            &state.oidc_client.id_token_verifier(),
            &Nonce::new(attempt.nonce.clone()),
        )
        .context("ID token validation failed")?;
    if let Some(expected_hash) = claims.access_token_hash() {
        let verifier = state.oidc_client.id_token_verifier();
        let signing_algorithm = id_token.signing_alg()?;
        let signing_key = id_token.signing_key(&verifier)?;
        let actual_hash = AccessTokenHash::from_token(
            token_response.access_token(),
            signing_algorithm,
            signing_key,
        )?;
        if actual_hash != *expected_hash {
            return Err(anyhow!("access token hash validation failed"));
        }
    }
    let claims_json = serde_json::to_value(claims)?;
    let pointer = dot_path_to_json_pointer(&state.config.username_claim);
    let username = claims_json
        .pointer(&pointer)
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty() && value.len() <= 128)
        .context("configured username claim is missing")?;
    if username.chars().any(char::is_control) {
        return Err(anyhow!("username contains control characters"));
    }
    Ok(username.to_string())
}

fn issue_ticket(key: &[u8], username: &str, state: &str) -> anyhow::Result<String> {
    let now = unix_time()?;
    let payload = TicketPayload {
        purpose: "easytier-native-login-v1".to_string(),
        username: username.to_string(),
        state: state.to_string(),
        issued_at: now,
        expires_at: now + TICKET_LIFETIME_SECONDS,
    };
    let encoded = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&payload)?);
    let signature = sign(key, format!("ets1:{encoded}").as_bytes())?;
    Ok(format!(
        "ets1.{encoded}.{}",
        URL_SAFE_NO_PAD.encode(signature)
    ))
}

fn verify_ticket(key: &[u8], ticket: &str) -> anyhow::Result<TicketPayload> {
    let mut parts = ticket.split('.');
    if parts.next() != Some("ets1") {
        return Err(anyhow!("unknown ticket version"));
    }
    let payload = parts.next().context("missing ticket payload")?;
    let signature = parts.next().context("missing ticket signature")?;
    if parts.next().is_some() {
        return Err(anyhow!("invalid ticket shape"));
    }
    let signature = URL_SAFE_NO_PAD.decode(signature)?;
    let mut mac = Hmac::<Sha256>::new_from_slice(key)?;
    mac.update(format!("ets1:{payload}").as_bytes());
    mac.verify_slice(&signature)
        .map_err(|_| anyhow!("invalid ticket signature"))?;
    let payload: TicketPayload = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload)?)?;
    let now = unix_time()?;
    if payload.purpose != "easytier-native-login-v1"
        || payload.issued_at > now.saturating_add(30)
        || payload.expires_at < now
        || payload.expires_at.saturating_sub(payload.issued_at) != TICKET_LIFETIME_SECONDS
    {
        return Err(anyhow!("ticket is expired or has invalid claims"));
    }
    Ok(payload)
}

fn sign(key: &[u8], message: &[u8]) -> anyhow::Result<Vec<u8>> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key)?;
    mac.update(message);
    Ok(mac.finalize().into_bytes().to_vec())
}

fn coordinator_html(port: u16, state: &str, nonce: &str) -> String {
    format!(
        r#"<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>EasyTier Sign In</title>
<style nonce="{nonce}">:root{{color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,sans-serif}}body{{min-height:100vh;margin:0;display:grid;place-items:center;background:linear-gradient(145deg,#eef7f2,#dce9e2)}}main{{width:min(420px,calc(100vw - 48px));padding:32px;border:1px solid #ffffff90;border-radius:22px;background:#ffffffd9;box-shadow:0 24px 80px #173c2a26;color:#14251c}}h1{{margin:0 0 12px}}p{{line-height:1.5;color:#4c5e54}}a{{display:block;margin-top:24px;padding:12px 18px;border-radius:12px;background:#176b45;color:white;text-align:center;text-decoration:none}}#status{{font-size:14px}}@media(prefers-color-scheme:dark){{body{{background:linear-gradient(145deg,#10231a,#172c22)}}main{{background:#17251f;color:#edf7f1;border-color:#ffffff20}}p{{color:#b6c8be}}}}</style></head>
<body><main><h1>Sign in to EasyTier</h1><p>Continue with SSO in the browser. This page will finish signing in the Mac app automatically.</p><a id="start" href="/native/oidc/start" target="easytier-sso">Continue with SSO</a><p id="status">Waiting for you to continue...</p></main>
<script nonce="{nonce}">const status=document.getElementById('status');document.getElementById('start').addEventListener('click',()=>{{status.textContent='Completing browser sign-in...';}});async function poll(){{try{{const nativeResponse=await fetch('/native/status',{{cache:'no-store',credentials:'same-origin'}});const native=await nativeResponse.json();if(native.status==='failed'){{status.textContent='Sign-in expired or failed. Return to EasyTier and try again.';return;}}if(native.status==='authenticated'){{const web=await fetch('/api/v1/auth/check_login_status',{{cache:'no-store',credentials:'same-origin'}});if(web.ok){{const target=new URL('http://127.0.0.1:{port}/easytier/callback');target.searchParams.set('state','{state}');target.searchParams.set('ticket',native.ticket);location.replace(target);return;}}}}}}catch(_){{}}setTimeout(poll,750)}}poll();</script></body></html>"#,
        nonce = nonce,
        port = port,
        state = state,
    )
}

fn html_response(html: String, nonce: &str, cookie: Option<String>) -> Response {
    let mut response = Html(html).into_response();
    let headers = response.headers_mut();
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    headers.insert("referrer-policy", HeaderValue::from_static("no-referrer"));
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_str(&format!(
            "default-src 'none'; script-src 'nonce-{nonce}'; style-src 'nonce-{nonce}'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
        ))
        .expect("generated CSP is valid"),
    );
    if let Some(cookie) = cookie {
        headers.insert(
            header::SET_COOKIE,
            HeaderValue::from_str(&cookie).expect("cookie is valid"),
        );
    }
    response
}

fn safe_error(status: StatusCode, message: &'static str) -> Response {
    let mut response = (
        status,
        Html(format!(
            "<!doctype html><title>EasyTier Sign In</title><p>{message}</p>"
        )),
    )
        .into_response();
    secure_no_store_headers(response.headers_mut());
    response
}

fn safe_json_error(status: StatusCode, message: &'static str) -> Response {
    let mut response = (status, Json(serde_json::json!({ "error": message }))).into_response();
    secure_no_store_headers(response.headers_mut());
    response
}

fn no_store_json<T: Serialize>(body: Json<T>) -> Response {
    let mut response = body.into_response();
    secure_no_store_headers(response.headers_mut());
    response
}

fn secure_no_store_headers(headers: &mut HeaderMap) {
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    headers.insert("referrer-policy", HeaderValue::from_static("no-referrer"));
}

async fn mark_flow_failed(state: &AppState, flow_id: &str) {
    if let Some(flow) = state.flows.lock().await.get_mut(flow_id) {
        flow.outcome = FlowOutcome::Failed;
    }
}

async fn prune_expired(state: &AppState) {
    state
        .flows
        .lock()
        .await
        .retain(|_, flow| flow.created_at.elapsed() <= FLOW_LIFETIME);
    state
        .attempts
        .lock()
        .await
        .retain(|_, attempt| attempt.created_at.elapsed() <= FLOW_LIFETIME);
}

fn flow_cookie(headers: &HeaderMap) -> Option<String> {
    headers
        .get(header::COOKIE)?
        .to_str()
        .ok()?
        .split(';')
        .filter_map(|part| part.trim().split_once('='))
        .find_map(|(name, value)| (name == FLOW_COOKIE).then(|| value.to_string()))
        .filter(|value| {
            URL_SAFE_NO_PAD
                .decode(value)
                .is_ok_and(|bytes| bytes.len() == 32)
        })
}

fn valid_native_state(value: &str) -> bool {
    value.len() <= 128
        && URL_SAFE_NO_PAD
            .decode(value)
            .is_ok_and(|bytes| bytes.len() == 32)
}

fn dot_path_to_json_pointer(path: &str) -> String {
    path.split('.').fold(String::new(), |mut pointer, segment| {
        pointer.push('/');
        pointer.push_str(&segment.replace('~', "~0").replace('/', "~1"));
        pointer
    })
}

fn parse_public_origin(value: &str) -> anyhow::Result<Url> {
    let url = Url::parse(value)?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || url.username() != ""
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() != "/"
    {
        return Err(anyhow!("SIDECAR_PUBLIC_ORIGIN must be a pure HTTPS origin"));
    }
    Ok(url)
}

fn validate_config_endpoint(value: &str) -> anyhow::Result<String> {
    let url = Url::parse(value)?;
    if url.scheme() != "tcp"
        || url.host_str().is_none()
        || url.port().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !matches!(url.path(), "" | "/")
    {
        return Err(anyhow!(
            "SIDECAR_CONFIG_ENDPOINT must be a tcp://host:port endpoint"
        ));
    }
    Ok(value.to_string())
}

fn required_env(name: &str) -> anyhow::Result<String> {
    env::var(name).with_context(|| format!("{name} is required"))
}

fn random_base64url(byte_count: usize) -> String {
    let mut bytes = vec![0_u8; byte_count];
    OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

fn unix_time() -> anyhow::Result<u64> {
    Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ticket_round_trip_and_tamper_rejection() {
        let key = [7_u8; 32];
        let state = random_base64url(32);
        let ticket = issue_ticket(&key, "oidc-admin", &state).unwrap();
        let payload = verify_ticket(&key, &ticket).unwrap();
        assert_eq!(payload.username, "oidc-admin");
        assert_eq!(payload.state, state);

        let mut tampered = ticket.into_bytes();
        let last = tampered.last_mut().unwrap();
        *last = if *last == b'A' { b'B' } else { b'A' };
        assert!(verify_ticket(&key, std::str::from_utf8(&tampered).unwrap()).is_err());
    }

    #[test]
    fn validates_native_state_and_endpoints() {
        assert!(valid_native_state(&random_base64url(32)));
        assert!(!valid_native_state("short"));
        assert!(validate_config_endpoint("tcp://iw.example.com:22020").is_ok());
        assert!(validate_config_endpoint("https://iw.example.com").is_err());
        assert!(parse_public_origin("https://iw.example.com").is_ok());
        assert!(parse_public_origin("https://iw.example.com/path").is_err());
    }
}
