use std::{
    ffi::{CStr, CString, c_char, c_int},
    sync::{Arc, LazyLock, Mutex},
};

#[cfg(feature = "core")]
use dashmap::DashMap;
#[cfg(feature = "core")]
use easytier::{
    common::config::{ConfigFileControl, ConfigLoader as _, TomlConfigLoader},
    instance_manager::NetworkInstanceManager,
    proto::{
        api::{
            config::{ConfigRpc, ConfigRpcClientFactory},
            instance::{
                InstanceIdentifier, PortForwardManageRpc, PortForwardManageRpcClientFactory,
            },
        },
        rpc_impl::standalone::StandAloneClient,
        rpc_types::controller::BaseController,
    },
    rpc_service::ApiRpcServer,
    tunnel::tcp::{TcpTunnelConnector, TcpTunnelListener},
};
#[cfg(feature = "core")]
use serde_json::Value;
#[cfg(feature = "core")]
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    time::{Duration, Instant},
};
use tokio::runtime::Runtime;
#[cfg(feature = "core")]
use tokio::{
    sync::{OwnedSemaphorePermit, Semaphore},
    time::timeout,
};
#[cfg(feature = "core")]
use url::{Host, Url};

#[cfg(feature = "gateway")]
mod gateway;

#[cfg(feature = "core")]
type RpcPortalServer = ApiRpcServer<TcpTunnelListener>;

#[cfg(feature = "core")]
static INSTANCE_NAME_ID_MAP: LazyLock<DashMap<String, uuid::Uuid>> = LazyLock::new(DashMap::new);
#[cfg(feature = "core")]
static INSTANCE_MANAGER: LazyLock<Arc<NetworkInstanceManager>> =
    LazyLock::new(|| Arc::new(NetworkInstanceManager::new()));
#[cfg(feature = "core")]
static RPC_CLIENTS: LazyLock<DashMap<String, Arc<RpcEndpoint>>> = LazyLock::new(DashMap::new);
#[cfg(feature = "core")]
static RPC_PORTAL_SERVER: LazyLock<Mutex<Option<RpcPortalServer>>> =
    LazyLock::new(|| Mutex::new(None));
#[cfg(feature = "gateway")]
static GATEWAY: LazyLock<Mutex<Option<Arc<gateway::GatewayHandle>>>> =
    LazyLock::new(|| Mutex::new(None));
#[cfg(feature = "gateway")]
static GATEWAY_OPERATION: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));
static RPC_RUNTIME: LazyLock<Runtime> = LazyLock::new(|| {
    #[cfg(feature = "gateway")]
    gateway::install_rustls_crypto_provider()
        .expect("failed to install the Rustls crypto provider");
    Runtime::new().expect("failed to create EasyTier RPC runtime")
});
#[cfg(feature = "core")]
static RPC_TOTAL_LIMIT: LazyLock<Arc<Semaphore>> =
    LazyLock::new(|| Arc::new(Semaphore::new(RPC_MAX_CONCURRENT_TOTAL)));
#[cfg(feature = "core")]
static RPC_CONNECTING_LIMIT: LazyLock<Arc<Semaphore>> =
    LazyLock::new(|| Arc::new(Semaphore::new(RPC_MAX_CONNECTING_TOTAL)));
#[cfg(feature = "core")]
const RPC_CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
#[cfg(feature = "core")]
const RPC_CALL_TIMEOUT: Duration = Duration::from_secs(8);
#[cfg(feature = "core")]
const RPC_QUEUE_TIMEOUT: Duration = Duration::from_secs(2);
#[cfg(feature = "core")]
const RPC_UNAVAILABLE_COOLDOWN: Duration = Duration::from_secs(5);
#[cfg(feature = "core")]
const RPC_MAX_CONCURRENT_PER_ENDPOINT: usize = 4;
#[cfg(feature = "core")]
const RPC_MAX_CONCURRENT_TOTAL: usize = 32;
#[cfg(feature = "core")]
const RPC_MAX_CONNECTING_TOTAL: usize = 8;

#[cfg(feature = "core")]
struct RpcEndpoint {
    url: String,
    limit: Arc<Semaphore>,
    state: Mutex<RpcEndpointState>,
    /// Persistent `StandAloneClient` reused across `call_json_rpc` invocations so that
    /// TCP connections are kept alive between calls instead of being re-established.
    /// Guarded by a tokio mutex because `scoped_client` is async and needs `&mut self`.
    client: tokio::sync::Mutex<StandAloneClient<TcpTunnelConnector>>,
}

#[cfg(feature = "core")]
#[derive(Default)]
struct RpcEndpointState {
    cooldown_until: Option<Instant>,
    last_error: Option<String>,
}

#[cfg(feature = "core")]
impl RpcEndpoint {
    fn new(url: String, parsed_url: Url) -> Self {
        Self {
            url,
            limit: Arc::new(Semaphore::new(RPC_MAX_CONCURRENT_PER_ENDPOINT)),
            state: Mutex::new(RpcEndpointState::default()),
            client: tokio::sync::Mutex::new(StandAloneClient::new(TcpTunnelConnector::new(
                parsed_url,
            ))),
        }
    }

    fn check_cooldown(&self) -> Result<(), String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "RPC endpoint state lock is poisoned".to_string())?;
        let Some(until) = state.cooldown_until else {
            return Ok(());
        };

        let now = Instant::now();
        if until <= now {
            state.cooldown_until = None;
            state.last_error = None;
            return Ok(());
        }

        let remaining = until.saturating_duration_since(now).as_secs_f32();
        let last_error = state
            .last_error
            .as_deref()
            .unwrap_or("remote RPC endpoint is unavailable");
        Err(format!(
            "Remote EasyTier RPC endpoint is cooling down for {remaining:.1}s after a connection failure: {last_error}"
        ))
    }

    fn set_connect_cooldown(&self, message: impl Into<String>) {
        if let Ok(mut state) = self.state.lock() {
            state.cooldown_until = Some(Instant::now() + RPC_UNAVAILABLE_COOLDOWN);
            state.last_error = Some(message.into());
        }
    }

    fn clear_cooldown(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.cooldown_until = None;
            state.last_error = None;
        }
    }
}

#[repr(C)]
#[cfg(feature = "core")]
pub struct KeyValuePair {
    pub key: *const c_char,
    pub value: *const c_char,
}

/// Write an error message into the caller-provided out-param.
///
/// On success the caller observes a null pointer; on failure the caller owns the returned
/// `CString` and must release it with `free_string`.
///
/// # Safety
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null.
unsafe fn write_error_out(out_error: *mut *const c_char, message: &str) {
    if !out_error.is_null() {
        let sanitized = message.replace('\0', "\\0");
        let cstr = CString::new(sanitized.as_bytes()).unwrap_or_else(|_| {
            CString::new("EasyTier FFI error contained an invalid NUL byte").unwrap()
        });
        // SAFETY: `out_error` was checked for null and points to caller-owned storage.
        unsafe {
            *out_error = cstr.into_raw();
        }
    }
}

/// Clear the out-param error slot on success.
///
/// # Safety
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null.
unsafe fn clear_error_out(out_error: *mut *const c_char) {
    if !out_error.is_null() {
        // SAFETY: `out_error` was checked for null and points to caller-owned storage.
        unsafe {
            *out_error = std::ptr::null();
        }
    }
}

unsafe fn cstr_arg(ptr: *const c_char, name: &str) -> Result<String, String> {
    if ptr.is_null() {
        return Err(format!("{name} must not be null"));
    }

    // SAFETY: The caller must pass a valid NUL-terminated C string pointer.
    let cstr = unsafe { CStr::from_ptr(ptr) };
    cstr.to_str()
        .map(str::to_owned)
        .map_err(|e| format!("{name} must be valid UTF-8: {e}"))
}

/// Resolve caller-provided instance names to the UUIDs known by the instance manager.
///
/// # Safety
/// When `length > 0`, `inst_names` must point to `length` valid C string pointers.
#[cfg(feature = "core")]
unsafe fn instance_names_and_ids(
    inst_names: *const *const c_char,
    length: usize,
) -> Result<(Vec<String>, Vec<uuid::Uuid>), String> {
    if length == 0 {
        return Ok((Vec::new(), Vec::new()));
    }
    if inst_names.is_null() {
        return Err("inst_names must not be null when length is greater than zero".to_string());
    }

    // SAFETY: `inst_names` is checked for null and the caller promises `length` valid entries.
    let inst_names = unsafe { std::slice::from_raw_parts(inst_names, length) }
        .iter()
        .enumerate()
        .map(|(index, &name)| {
            // SAFETY: Each entry is a caller-owned C string pointer; null/UTF-8 are checked.
            unsafe { cstr_arg(name, &format!("inst_names[{index}]")) }
        })
        .collect::<Result<Vec<_>, _>>()?;

    let mut inst_ids = inst_names
        .iter()
        .filter_map(|name| INSTANCE_NAME_ID_MAP.get(name).map(|id| *id))
        .collect::<Vec<_>>();
    inst_ids.reverse();
    Ok((inst_names, inst_ids))
}

fn write_cstring_out(value: String, out: *mut *const c_char) -> Result<(), String> {
    if out.is_null() {
        return Err("out_json must not be null".to_string());
    }
    let cstr = CString::new(value).map_err(|e| format!("output contained a NUL byte: {e}"))?;
    // SAFETY: `out` was checked for null and points to caller-owned storage for one pointer.
    unsafe {
        *out = cstr.into_raw();
    }
    Ok(())
}

/// Run `operation` and map its result to the FFI convention:
/// - `Ok(())` → returns 0, clears `out_error`
/// - `Err(e)` → returns -1, writes `e` into `out_error` (if non-null)
///
/// # Safety
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null.
unsafe fn ffi_result_with_error(
    out_error: *mut *const c_char,
    operation: impl FnOnce() -> Result<(), String>,
) -> c_int {
    match operation() {
        Ok(()) => {
            // SAFETY: caller owns `out_error` storage; null is a valid sentinel for "no error".
            unsafe { clear_error_out(out_error) };
            0
        }
        Err(error) => {
            // SAFETY: caller owns `out_error` storage; `write_error_out` checks for null.
            unsafe { write_error_out(out_error, &error) };
            -1
        }
    }
}

#[cfg(feature = "core")]
fn validate_rpc_url(raw: &str) -> Result<Url, String> {
    let url = Url::parse(raw).map_err(|e| format!("invalid RPC URL: {e}"))?;
    if url.scheme() != "tcp" {
        return Err("RPC URL must use tcp://".to_string());
    }
    if url.port().is_none() {
        return Err("RPC URL must include a port".to_string());
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err("RPC URL must not include credentials".to_string());
    }
    if !(url.path().is_empty() || url.path() == "/")
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("RPC URL must not include path, query, or fragment".to_string());
    }

    let ip = match url.host() {
        Some(Host::Ipv4(addr)) => IpAddr::V4(addr),
        Some(Host::Ipv6(addr)) => IpAddr::V6(addr),
        Some(Host::Domain(host)) => host
            .trim_start_matches('[')
            .trim_end_matches(']')
            .parse::<IpAddr>()
            .map_err(|_| "RPC URL host must be an IP address, not a domain name".to_string())?,
        None => return Err("RPC URL must include an IP host".to_string()),
    };
    if !is_allowed_rpc_ip(ip) {
        return Err(
            "RPC URL host must be private, loopback, link-local, or EasyTier virtual IP"
                .to_string(),
        );
    }

    Ok(url)
}

#[cfg(feature = "core")]
fn normalize_rpc_portal(raw: &str) -> Result<String, String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err("RPC portal listen address must not be empty".to_string());
    }
    if !raw.contains("://") {
        return Ok(raw.to_string());
    }

    let url = Url::parse(raw).map_err(|e| format!("invalid RPC portal URL: {e}"))?;
    if url.scheme() != "tcp" {
        return Err("RPC portal must use tcp://".to_string());
    }
    let port = url
        .port()
        .ok_or_else(|| "RPC portal must include a port".to_string())?;
    match url.host() {
        Some(Host::Ipv4(addr)) => Ok(format!("{addr}:{port}")),
        Some(Host::Ipv6(addr)) => Ok(format!("[{addr}]:{port}")),
        Some(Host::Domain(host)) => Ok(format!("{host}:{port}")),
        None => Err("RPC portal must include a host".to_string()),
    }
}

#[cfg(feature = "core")]
fn is_allowed_rpc_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(addr) => is_allowed_ipv4(addr),
        IpAddr::V6(addr) => is_allowed_ipv6(addr),
    }
}

#[cfg(feature = "core")]
fn is_allowed_ipv4(addr: Ipv4Addr) -> bool {
    let octets = addr.octets();
    match octets {
        [10, _, _, _] => true,
        [172, second, _, _] if (16..=31).contains(&second) => true,
        [192, 168, _, _] => true,
        [127, _, _, _] => true,
        [169, 254, _, _] => true,
        [100, second, _, _] if (64..=127).contains(&second) => true,
        _ => false,
    }
}

#[cfg(feature = "core")]
fn is_allowed_ipv6(addr: Ipv6Addr) -> bool {
    let first = addr.segments()[0];
    addr.is_loopback() || (first & 0xfe00) == 0xfc00 || (first & 0xffc0) == 0xfe80
}

#[cfg(feature = "core")]
fn is_allowed_service_method(service_name: &str, method_name: &str) -> bool {
    match service_name {
        "api.config.ConfigRpcService" => matches!(method_name, "patch_config" | "get_config"),
        "api.instance.PortForwardManageRpcService" => method_name == "list_port_forward",
        _ => false,
    }
}

#[cfg(feature = "core")]
async fn acquire_rpc_permit(
    semaphore: Arc<Semaphore>,
    label: &str,
    wait: Duration,
) -> Result<OwnedSemaphorePermit, String> {
    timeout(wait, semaphore.acquire_owned())
        .await
        .map_err(|_| {
            format!("EasyTier RPC is busy waiting for {label} capacity. Try again shortly.")
        })?
        .map_err(|_| format!("EasyTier RPC {label} limiter is closed."))
}

#[cfg(feature = "core")]
async fn call_rpc_by_service(
    endpoint: Arc<RpcEndpoint>,
    service_name: &str,
    method_name: &str,
    domain: String,
    payload: Value,
) -> Result<Value, String> {
    endpoint.check_cooldown()?;
    let _global_permit =
        acquire_rpc_permit(RPC_TOTAL_LIMIT.clone(), "global RPC", RPC_QUEUE_TIMEOUT).await?;
    let _endpoint_permit =
        acquire_rpc_permit(endpoint.limit.clone(), "endpoint RPC", RPC_QUEUE_TIMEOUT).await?;

    // Reuse the persistent `StandAloneClient` stored on the endpoint. `scoped_client`
    // internally reconnects only when the previous tunnel errored or was never
    // established, so consecutive calls share the same TCP connection.
    let mut client_guard = endpoint.client.lock().await;

    macro_rules! call_service {
        ($factory:ty) => {{
            let connect_permit = acquire_rpc_permit(
                RPC_CONNECTING_LIMIT.clone(),
                "TCP connect",
                RPC_QUEUE_TIMEOUT,
            )
            .await?;
            let stub = match timeout(
                RPC_CONNECT_TIMEOUT,
                client_guard.scoped_client::<$factory>(domain),
            )
            .await
            {
                Ok(Ok(stub)) => {
                    drop(connect_permit);
                    endpoint.clear_cooldown();
                    stub
                }
                Ok(Err(e)) => {
                    drop(connect_permit);
                    let message = format!("Remote EasyTier RPC endpoint is unavailable: {e:#}");
                    endpoint.set_connect_cooldown(message.clone());
                    return Err(message);
                }
                Err(_) => {
                    drop(connect_permit);
                    let message = format!(
                        "Remote EasyTier RPC connect timed out after {} seconds.",
                        RPC_CONNECT_TIMEOUT.as_secs()
                    );
                    endpoint.set_connect_cooldown(message.clone());
                    return Err(message);
                }
            };

            match timeout(
                RPC_CALL_TIMEOUT,
                stub.json_call_method(BaseController::default(), method_name, payload),
            )
            .await
            {
                Ok(Ok(value)) => Ok(value),
                Ok(Err(e)) => Err(format!("RPC Error: {e:?}")),
                Err(_) => Err(format!(
                    "EasyTier RPC request timed out after {} seconds.",
                    RPC_CALL_TIMEOUT.as_secs()
                )),
            }
        }};
    }

    match service_name {
        "api.config.ConfigRpcService" => {
            call_service!(ConfigRpcClientFactory<BaseController>)
        }
        "api.instance.PortForwardManageRpcService" => {
            call_service!(PortForwardManageRpcClientFactory<BaseController>)
        }
        _ => Err(format!("Unknown service: {service_name}")),
    }
}

/// # Safety
/// `s` must be null or a pointer returned by this library from `CString::into_raw`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn free_string(s: *const c_char) {
    if s.is_null() {
        return;
    }
    // SAFETY: Callers must only pass pointers returned by this library via CString::into_raw.
    unsafe {
        let _ = CString::from_raw(s as *mut c_char);
    }
}

/// Start the TLS gateway from a versioned configuration and separate secrets document.
///
/// Certificate issuance continues asynchronously after the listeners have started. Use
/// `gateway_status` to observe certificate readiness.
///
/// # Safety
/// `config_json` and `secrets_json` must be valid NUL-terminated UTF-8 strings.
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null.
#[unsafe(no_mangle)]
#[cfg(feature = "gateway")]
pub unsafe extern "C" fn gateway_start(
    config_json: *const c_char,
    secrets_json: *const c_char,
    out_error: *mut *const c_char,
) -> c_int {
    // SAFETY: `out_error` is caller-owned storage or null.
    unsafe {
        ffi_result_with_error(out_error, || {
            let _operation = GATEWAY_OPERATION
                .lock()
                .map_err(|_| "gateway operation lock is poisoned".to_string())?;
            if GATEWAY
                .lock()
                .map_err(|_| "gateway state lock is poisoned".to_string())?
                .is_some()
            {
                return Err("gateway is already running".to_string());
            }

            // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
            let config_json = cstr_arg(config_json, "config_json")?;
            // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
            let secrets_json = cstr_arg(secrets_json, "secrets_json")?;
            let gateway = Arc::new(
                RPC_RUNTIME.block_on(gateway::GatewayHandle::start(&config_json, &secrets_json))?,
            );
            *GATEWAY
                .lock()
                .map_err(|_| "gateway state lock is poisoned".to_string())? = Some(gateway);
            Ok(())
        })
    }
}

/// Atomically replace the gateway route/certificate snapshot.
///
/// Passing a null `secrets_json_or_null` retains the currently loaded in-memory secrets.
///
/// # Safety
/// Non-null string pointers must reference valid NUL-terminated UTF-8 strings.
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null.
#[unsafe(no_mangle)]
#[cfg(feature = "gateway")]
pub unsafe extern "C" fn gateway_apply_config(
    config_json: *const c_char,
    secrets_json_or_null: *const c_char,
    out_error: *mut *const c_char,
) -> c_int {
    // SAFETY: `out_error` is caller-owned storage or null.
    unsafe {
        ffi_result_with_error(out_error, || {
            let _operation = GATEWAY_OPERATION
                .lock()
                .map_err(|_| "gateway operation lock is poisoned".to_string())?;
            let gateway = GATEWAY
                .lock()
                .map_err(|_| "gateway state lock is poisoned".to_string())?
                .clone()
                .ok_or_else(|| "gateway is not running".to_string())?;
            // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
            let config_json = cstr_arg(config_json, "config_json")?;
            let secrets_json = if secrets_json_or_null.is_null() {
                None
            } else {
                // SAFETY: The pointer is non-null and owned by the C ABI caller.
                Some(cstr_arg(secrets_json_or_null, "secrets_json_or_null")?)
            };
            RPC_RUNTIME.block_on(gateway.apply_config(&config_json, secrets_json.as_deref()))
        })
    }
}

/// Stop the gateway. Calling this while already stopped succeeds.
///
/// # Safety
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null.
#[unsafe(no_mangle)]
#[cfg(feature = "gateway")]
pub unsafe extern "C" fn gateway_stop(out_error: *mut *const c_char) -> c_int {
    // SAFETY: `out_error` is caller-owned storage or null.
    unsafe {
        ffi_result_with_error(out_error, || {
            let _operation = GATEWAY_OPERATION
                .lock()
                .map_err(|_| "gateway operation lock is poisoned".to_string())?;
            let gateway = GATEWAY
                .lock()
                .map_err(|_| "gateway state lock is poisoned".to_string())?
                .clone();
            let Some(gateway) = gateway else {
                return Ok(());
            };

            let result = RPC_RUNTIME.block_on(gateway.stop());
            let mut slot = GATEWAY
                .lock()
                .map_err(|_| "gateway state lock is poisoned".to_string())?;
            if slot
                .as_ref()
                .is_some_and(|current| Arc::ptr_eq(current, &gateway))
            {
                *slot = None;
            }
            result
        })
    }
}

/// Return the current versioned gateway status document.
///
/// # Safety
/// `out_json` must point to caller-owned storage for one string pointer. The returned string must
/// be released with `free_string`. `out_error` follows the same ownership convention.
#[unsafe(no_mangle)]
#[cfg(feature = "gateway")]
pub unsafe extern "C" fn gateway_status(
    out_json: *mut *const c_char,
    out_error: *mut *const c_char,
) -> c_int {
    // SAFETY: `out_error` is caller-owned storage or null.
    unsafe {
        ffi_result_with_error(out_error, || {
            if !out_json.is_null() {
                // SAFETY: `out_json` was checked for null and points to caller-owned storage.
                *out_json = std::ptr::null();
            }
            let gateway = GATEWAY
                .lock()
                .map_err(|_| "gateway state lock is poisoned".to_string())?
                .clone();
            let status = match gateway {
                Some(gateway) => gateway.status_json()?,
                None => gateway::stopped_status_json()?,
            };
            write_cstring_out(status, out_json)
        })
    }
}

/// Queue renewal for one certificate, or all certificates for a null/empty identifier.
///
/// # Safety
/// A non-null `certificate_id_or_null` must reference a valid NUL-terminated UTF-8 string.
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null.
#[unsafe(no_mangle)]
#[cfg(feature = "gateway")]
pub unsafe extern "C" fn gateway_request_renewal(
    certificate_id_or_null: *const c_char,
    out_error: *mut *const c_char,
) -> c_int {
    // SAFETY: `out_error` is caller-owned storage or null.
    unsafe {
        ffi_result_with_error(out_error, || {
            let _operation = GATEWAY_OPERATION
                .lock()
                .map_err(|_| "gateway operation lock is poisoned".to_string())?;
            let gateway = GATEWAY
                .lock()
                .map_err(|_| "gateway state lock is poisoned".to_string())?
                .clone()
                .ok_or_else(|| "gateway is not running".to_string())?;
            let certificate_id = if certificate_id_or_null.is_null() {
                None
            } else {
                // SAFETY: The pointer is non-null and owned by the C ABI caller.
                let value = cstr_arg(certificate_id_or_null, "certificate_id_or_null")?;
                (!value.is_empty()).then_some(value)
            };
            RPC_RUNTIME.block_on(gateway.request_renewal(certificate_id))
        })
    }
}

/// # Safety
/// `cfg_str` must be a valid NUL-terminated C string pointer.
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null.
#[unsafe(no_mangle)]
#[cfg(feature = "core")]
pub unsafe extern "C" fn parse_config(
    cfg_str: *const c_char,
    out_error: *mut *const c_char,
) -> c_int {
    // SAFETY: `out_error` is caller-owned storage or null.
    unsafe {
        ffi_result_with_error(out_error, || {
            // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
            let cfg_str = cstr_arg(cfg_str, "cfg_str")?;
            TomlConfigLoader::new_from_str(&cfg_str)
                .map(|_| ())
                .map_err(|e| format!("failed to parse config: {e:?}"))
        })
    }
}

/// # Safety
/// `cfg_str` must be a valid NUL-terminated C string pointer.
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null.
#[unsafe(no_mangle)]
#[cfg(feature = "core")]
pub unsafe extern "C" fn run_network_instance(
    cfg_str: *const c_char,
    out_error: *mut *const c_char,
) -> c_int {
    // SAFETY: `out_error` is caller-owned storage or null.
    unsafe {
        ffi_result_with_error(out_error, || {
            // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
            let cfg_str = cstr_arg(cfg_str, "cfg_str")?;
            let cfg = TomlConfigLoader::new_from_str(&cfg_str)
                .map_err(|e| format!("failed to parse config: {e}"))?;

            let inst_name = cfg.get_inst_name();
            if INSTANCE_NAME_ID_MAP.contains_key(&inst_name) {
                return Err("instance already exists".to_string());
            }

            let instance_id = RPC_RUNTIME
                .block_on(async {
                    INSTANCE_MANAGER.run_network_instance(
                        cfg,
                        true,
                        ConfigFileControl::STATIC_CONFIG,
                    )
                })
                .map_err(|e| format!("failed to start instance: {e}"))?;

            INSTANCE_NAME_ID_MAP.insert(inst_name, instance_id);
            Ok(())
        })
    }
}

/// # Safety
/// When `length > 0`, `inst_names` must point to an array of valid NUL-terminated C strings.
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null.
#[unsafe(no_mangle)]
#[cfg(feature = "core")]
pub unsafe extern "C" fn retain_network_instance(
    inst_names: *const *const c_char,
    length: usize,
    out_error: *mut *const c_char,
) -> c_int {
    // SAFETY: `out_error` is caller-owned storage or null.
    unsafe {
        ffi_result_with_error(out_error, || {
            // SAFETY: The C ABI caller owns the array and C string pointer validity.
            let (inst_names, inst_ids) = instance_names_and_ids(inst_names, length)?;
            if inst_names.is_empty() {
                INSTANCE_MANAGER
                    .retain_network_instance(Vec::new())
                    .map_err(|e| format!("failed to retain instances: {e}"))?;
                INSTANCE_NAME_ID_MAP.clear();
                return Ok(());
            }

            INSTANCE_MANAGER
                .retain_network_instance(inst_ids)
                .map_err(|e| format!("failed to retain instances: {e}"))?;
            INSTANCE_NAME_ID_MAP.retain(|k, _| inst_names.contains(k));
            Ok(())
        })
    }
}

/// # Safety
/// When `length > 0`, `inst_names` must point to an array of valid NUL-terminated C strings.
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null.
#[unsafe(no_mangle)]
#[cfg(feature = "core")]
pub unsafe extern "C" fn stop_network_instance(
    inst_names: *const *const c_char,
    length: usize,
    out_error: *mut *const c_char,
) -> c_int {
    // SAFETY: `out_error` is caller-owned storage or null.
    unsafe {
        ffi_result_with_error(out_error, || {
            // SAFETY: The C ABI caller owns the array and C string pointer validity.
            let (inst_names, inst_ids) = instance_names_and_ids(inst_names, length)?;
            if inst_names.is_empty() {
                return Ok(());
            }

            INSTANCE_MANAGER
                .delete_network_instance(inst_ids)
                .map_err(|e| format!("failed to stop instances: {e}"))?;
            INSTANCE_NAME_ID_MAP.retain(|k, _| !inst_names.contains(k));
            Ok(())
        })
    }
}

/// # Safety
/// `infos` must point to writable storage for `max_length` `KeyValuePair` values.
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null.
#[unsafe(no_mangle)]
#[cfg(feature = "core")]
pub unsafe extern "C" fn collect_network_infos(
    infos: *mut KeyValuePair,
    max_length: usize,
    out_error: *mut *const c_char,
) -> c_int {
    let result = || -> Result<c_int, String> {
        if max_length == 0 {
            return Ok(0);
        }
        if infos.is_null() {
            return Err("infos must not be null when max_length is greater than zero".to_string());
        }

        // SAFETY: `infos` is checked for null and caller promises `max_length` writable entries.
        let infos = unsafe { std::slice::from_raw_parts_mut(infos, max_length) };

        let collected_infos = RPC_RUNTIME
            .block_on(INSTANCE_MANAGER.collect_network_infos())
            .map_err(|e| format!("failed to collect network infos: {e}"))?;

        let mut pending_pairs = Vec::with_capacity(max_length.min(collected_infos.len()));
        for (instance_id, value) in collected_infos.iter() {
            if pending_pairs.len() >= max_length {
                break;
            }
            let Some(key) = INSTANCE_MANAGER.get_instance_name(instance_id) else {
                continue;
            };
            // Inject the UUID `instance_id` into the JSON value so the Swift side can
            // match running instances against `NetworkConfig.instance_id` (a UUID)
            // instead of relying on the instance name, which may collide or change.
            let mut json_value = serde_json::to_value(value)
                .map_err(|e| format!("failed to serialize instance info: {e}"))?;
            if let Some(obj) = json_value.as_object_mut() {
                obj.insert(
                    "instance_id".to_string(),
                    serde_json::Value::String(instance_id.to_string()),
                );
            }
            let value = serde_json::to_string(&json_value)
                .map_err(|e| format!("failed to serialize instance info: {e}"))?;

            let key = CString::new(key)
                .map_err(|e| format!("instance name contained a NUL byte: {e}"))?;
            let value = CString::new(value)
                .map_err(|e| format!("instance info contained a NUL byte: {e}"))?;
            pending_pairs.push((key, value));
        }

        let count = pending_pairs.len();
        for (slot, (key, value)) in infos.iter_mut().zip(pending_pairs) {
            *slot = KeyValuePair {
                key: key.into_raw(),
                value: value.into_raw(),
            };
        }

        Ok(count as c_int)
    };

    match result() {
        Ok(count) => {
            // SAFETY: caller owns `out_error` storage; null is a valid sentinel for "no error".
            unsafe { clear_error_out(out_error) };
            count
        }
        Err(error) => {
            // SAFETY: caller owns `out_error` storage; `write_error_out` checks for null.
            unsafe { write_error_out(out_error, &error) };
            -1
        }
    }
}

/// # Safety
/// When `enabled != 0`, `listen_addr` must be a valid NUL-terminated C string pointer.
/// When `whitelist_count > 0`, `whitelist` must point to an array of valid C string pointers.
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null.
#[unsafe(no_mangle)]
#[cfg(feature = "core")]
pub unsafe extern "C" fn configure_rpc_portal(
    enabled: c_int,
    listen_addr: *const c_char,
    whitelist: *const *const c_char,
    whitelist_count: usize,
    out_error: *mut *const c_char,
) -> c_int {
    // SAFETY: `out_error` is caller-owned storage or null.
    unsafe {
        ffi_result_with_error(out_error, || {
            let mut slot = RPC_PORTAL_SERVER
                .lock()
                .map_err(|_| "RPC portal lock is poisoned".to_string())?;
            *slot = None;

            if enabled == 0 {
                return Ok(());
            }

            // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
            let listen_addr = cstr_arg(listen_addr, "listen_addr")?;
            let listen_addr = normalize_rpc_portal(&listen_addr)?;

            if whitelist_count > 0 && whitelist.is_null() {
                return Err(
                    "whitelist must not be null when whitelist_count is greater than zero"
                        .to_string(),
                );
            }
            let whitelist = if whitelist_count == 0 {
                None
            } else {
                // SAFETY: `whitelist` is checked for null and caller promises `whitelist_count` entries.
                let values = std::slice::from_raw_parts(whitelist, whitelist_count)
                    .iter()
                    .enumerate()
                    .map(|(index, &value)| {
                        // SAFETY: Each entry is a caller-owned C string pointer; null/UTF-8 are checked.
                        cstr_arg(value, &format!("whitelist[{index}]"))?
                            .parse()
                            .map_err(|e| {
                                format!("invalid RPC portal whitelist entry #{index}: {e}")
                            })
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                Some(values)
            };

            let server = RPC_RUNTIME.block_on(async {
                let server =
                    ApiRpcServer::new(Some(listen_addr), whitelist, INSTANCE_MANAGER.clone())
                        .map_err(|e| format!("failed to create RPC portal: {e}"))?;
                server
                    .serve()
                    .await
                    .map_err(|e| format!("failed to start RPC portal: {e}"))
            })?;
            *slot = Some(server);
            Ok(())
        })
    }
}

/// # Safety
/// `client_id` and `url` must be valid NUL-terminated C string pointers.
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null.
#[unsafe(no_mangle)]
#[cfg(feature = "core")]
pub unsafe extern "C" fn connect_rpc_client(
    client_id: *const c_char,
    url: *const c_char,
    out_error: *mut *const c_char,
) -> c_int {
    // SAFETY: `out_error` is caller-owned storage or null.
    unsafe {
        ffi_result_with_error(out_error, || {
            // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
            let client_id = cstr_arg(client_id, "client_id")?;
            // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
            let url_string = cstr_arg(url, "url")?;
            if client_id.trim().is_empty() {
                return Err("client_id must not be empty".to_string());
            }
            register_rpc_client(client_id, url_string)
        })
    }
}

#[cfg(feature = "core")]
fn register_rpc_client(client_id: String, url_string: String) -> Result<(), String> {
    let url = validate_rpc_url(&url_string)?;

    if let Some(entry) = RPC_CLIENTS.get(&client_id)
        && entry.url == url_string
    {
        return entry.check_cooldown();
    }

    RPC_CLIENTS.insert(client_id, Arc::new(RpcEndpoint::new(url_string, url)));
    Ok(())
}

/// # Safety
/// String pointers must be valid NUL-terminated C strings. `out_json` must point to writable
/// storage for one C string pointer and must be released by calling `free_string`.
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null;
/// on failure it owns a `CString` that must be released with `free_string`.
#[unsafe(no_mangle)]
#[cfg(feature = "core")]
pub unsafe extern "C" fn call_json_rpc(
    client_id: *const c_char,
    service_name: *const c_char,
    method_name: *const c_char,
    domain: *const c_char,
    payload_json: *const c_char,
    out_json: *mut *const c_char,
    out_error: *mut *const c_char,
) -> c_int {
    // SAFETY: `out_error` is caller-owned storage or null.
    unsafe {
        ffi_result_with_error(out_error, || {
            if !out_json.is_null() {
                // SAFETY: `out_json` was checked for null and points to caller-owned storage.
                *out_json = std::ptr::null();
            }

            // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
            let client_id = cstr_arg(client_id, "client_id")?;
            // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
            let service_name = cstr_arg(service_name, "service_name")?;
            // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
            let method_name = cstr_arg(method_name, "method_name")?;
            let domain = if domain.is_null() {
                String::new()
            } else {
                // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
                cstr_arg(domain, "domain")?
            };
            // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
            let payload_json = cstr_arg(payload_json, "payload_json")?;
            let response_json =
                call_json_rpc_inner(client_id, service_name, method_name, domain, payload_json)?;
            write_cstring_out(response_json, out_json)
        })
    }
}

#[cfg(feature = "core")]
fn call_json_rpc_inner(
    client_id: String,
    service_name: String,
    method_name: String,
    domain: String,
    payload_json: String,
) -> Result<String, String> {
    let payload = serde_json::from_str::<Value>(&payload_json)
        .map_err(|e| format!("payload_json must be valid JSON: {e}"))?;
    let payload = normalize_instance_identifier_payload(payload);

    if !is_allowed_service_method(&service_name, &method_name) {
        return Err(format!(
            "RPC service or method is not allowed: {service_name}.{method_name}"
        ));
    }

    let endpoint = RPC_CLIENTS
        .get(&client_id)
        .map(|entry| Arc::clone(entry.value()))
        .ok_or_else(|| format!("RPC client is not connected: {client_id}"))?;

    let response = RPC_RUNTIME.block_on(call_rpc_by_service(
        endpoint,
        &service_name,
        &method_name,
        domain,
        payload,
    ))?;
    serde_json::to_string(&response).map_err(|e| format!("failed to serialize RPC response: {e}"))
}

#[cfg(feature = "core")]
fn normalize_instance_identifier_payload(mut payload: Value) -> Value {
    let Some(instance) = payload.get_mut("instance") else {
        return payload;
    };
    let Value::Object(instance) = instance else {
        return payload;
    };
    let Some(selector) = instance.get("selector").cloned() else {
        return payload;
    };

    let legacy_identifier = Value::Object(instance.clone());
    let legacy_is_supported = serde_json::from_value::<InstanceIdentifier>(legacy_identifier)
        .is_ok_and(|identifier| identifier.selector.is_some());
    if !legacy_is_supported {
        let Value::Object(mut selector) = selector else {
            return payload;
        };
        let replacement = if let Some(id) = selector.remove("Id") {
            Some(("id", id))
        } else {
            selector
                .remove("InstanceSelector")
                .map(|value| ("instanceSelector", value))
        };
        if let Some((key, value)) = replacement {
            instance.remove("selector");
            instance.insert(key.to_string(), value);
        }
    }

    payload
}

#[cfg(test)]
mod tests {
    use super::*;
    use easytier::proto::api::{
        config::PatchConfigRequest, instance::instance_identifier::Selector,
    };

    static GATEWAY_FFI_TEST_LOCK: Mutex<()> = Mutex::new(());

    struct GatewayTestCleanup;

    impl Drop for GatewayTestCleanup {
        fn drop(&mut self) {
            // SAFETY: A null error out-param is allowed by the C ABI.
            let _ = unsafe { gateway_stop(std::ptr::null_mut()) };
        }
    }

    #[test]
    fn rpc_url_validation_accepts_private_and_local_ips() {
        assert!(validate_rpc_url("tcp://10.0.0.1:15888").is_ok());
        assert!(validate_rpc_url("tcp://172.16.0.1:15888").is_ok());
        assert!(validate_rpc_url("tcp://192.168.1.2:15888").is_ok());
        assert!(validate_rpc_url("tcp://127.0.0.1:15888").is_ok());
        assert!(validate_rpc_url("tcp://100.64.0.1:15888").is_ok());
        assert!(validate_rpc_url("tcp://[fd00::1]:15888").is_ok());
    }

    #[test]
    fn rpc_url_validation_rejects_public_or_ambiguous_targets() {
        assert!(validate_rpc_url("http://10.0.0.1:15888").is_err());
        assert!(validate_rpc_url("tcp://8.8.8.8:15888").is_err());
        assert!(validate_rpc_url("tcp://public.example.com:15888").is_err());
        assert!(validate_rpc_url("tcp://10.0.0.1").is_err());
        assert!(validate_rpc_url("tcp://10.0.0.1:15888/path").is_err());
    }

    #[test]
    fn service_and_method_whitelist_is_explicit() {
        assert!(is_allowed_service_method(
            "api.config.ConfigRpcService",
            "patch_config"
        ));
        assert!(is_allowed_service_method(
            "api.config.ConfigRpcService",
            "get_config"
        ));
        assert!(is_allowed_service_method(
            "api.instance.PortForwardManageRpcService",
            "list_port_forward"
        ));
        assert!(!is_allowed_service_method(
            "api.instance.PeerManageRpcService",
            "list_peer"
        ));
        assert!(!is_allowed_service_method(
            "api.config.ConfigRpcService",
            "GetConfig"
        ));
        assert!(!is_allowed_service_method(
            "api.config.ConfigRpcService",
            "delete_everything"
        ));
    }

    #[test]
    fn closed_rpc_endpoint_enters_cooldown_and_expires() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);

        let client_id = format!("closed-port-{port}");
        let url = format!("tcp://127.0.0.1:{port}");
        register_rpc_client(client_id.clone(), url.clone()).unwrap();

        let payload = serde_json::json!({
            "instance": {
                "selector": {
                    "Id": {
                        "part1": 1,
                        "part2": 2,
                        "part3": 3,
                        "part4": 4
                    }
                }
            }
        })
        .to_string();

        let first = call_json_rpc_inner(
            client_id.clone(),
            "api.config.ConfigRpcService".to_string(),
            "get_config".to_string(),
            String::new(),
            payload,
        )
        .unwrap_err();
        assert!(first.contains("unavailable") || first.contains("timed out"));

        let cooling = register_rpc_client(client_id.clone(), url.clone()).unwrap_err();
        assert!(cooling.contains("cooling down"));

        let endpoint = RPC_CLIENTS.get(&client_id).unwrap().value().clone();
        {
            let mut state = endpoint.state.lock().unwrap();
            state.cooldown_until = Some(Instant::now() - Duration::from_secs(1));
        }
        assert!(register_rpc_client(client_id.clone(), url).is_ok());
        RPC_CLIENTS.remove(&client_id);
    }

    #[test]
    fn rpc_limiter_rejects_when_capacity_is_full() {
        RPC_RUNTIME.block_on(async {
            let semaphore = Arc::new(Semaphore::new(2));
            let _first = semaphore.clone().acquire_owned().await.unwrap();
            let _second = semaphore.clone().acquire_owned().await.unwrap();

            let error = acquire_rpc_permit(semaphore, "endpoint RPC", Duration::from_millis(10))
                .await
                .unwrap_err();

            assert!(error.contains("busy waiting for endpoint RPC capacity"));
        });
    }

    #[test]
    fn invalid_rpc_method_rejects_before_client_lookup() {
        let error = call_json_rpc_inner(
            "missing-client".to_string(),
            "api.config.ConfigRpcService".to_string(),
            "delete_everything".to_string(),
            String::new(),
            "{}".to_string(),
        )
        .unwrap_err();

        assert!(error.contains("not allowed"));
    }

    #[test]
    fn c_abi_null_pointer_returns_error() {
        let mut error: *const c_char = std::ptr::null();
        // SAFETY: This intentionally passes a null pointer to exercise the FFI guard.
        // `error` is valid writable storage for one pointer.
        let result = unsafe { parse_config(std::ptr::null(), &mut error) };
        assert_eq!(result, -1);
        assert!(!error.is_null());
        let message = unsafe { CStr::from_ptr(error) }.to_string_lossy();
        assert!(message.contains("cfg_str must not be null"));
        unsafe { free_string(error) };

        // Success path should clear the out-error slot.
        let valid_cfg = "instance_name = \"t\"\nnetwork_name = \"n\"\n";
        let mut error2: *const c_char = std::ptr::null();
        // SAFETY: `valid_cfg` is a valid NUL-terminated C string; `error2` is valid storage.
        let result2 =
            unsafe { parse_config(CString::new(valid_cfg).unwrap().as_ptr(), &mut error2) };
        assert_eq!(result2, 0);
        assert!(error2.is_null());
    }

    #[test]
    fn gateway_c_abi_lifecycle_is_atomic_and_redacts_secrets() {
        let _serial = GATEWAY_FFI_TEST_LOCK.lock().unwrap();
        let _cleanup = GatewayTestCleanup;
        // SAFETY: A null error out-param is allowed, and stop is idempotent.
        assert_eq!(unsafe { gateway_stop(std::ptr::null_mut()) }, 0);

        let temp = tempfile::tempdir().unwrap();
        let mut config = serde_json::json!({
            "schema_version": 4,
            "storage_dir": temp.path().join("gateway"),
            "listeners": {
                "http": "127.0.0.1:0",
                "https": "127.0.0.1:0",
                "dns": "127.0.0.1:0"
            },
            "local_dns": {
                "domains": [],
                "answer_ipv4": "127.0.0.1",
                "ttl": 30
            },
            "acme": {
                "directory": { "kind": "letsencrypt_staging" },
                "contact_email": null,
                "terms_of_service_agreed": true
            },
            "certificates": [],
            "routes": []
        });
        let secrets = serde_json::json!({
            "schema_version": 4,
            "cloudflare": {
                "cf-main": { "api_token": "super-secret-cloudflare-token" }
            }
        });
        let config_string = CString::new(config.to_string()).unwrap();
        let secrets_string = CString::new(secrets.to_string()).unwrap();
        let mut error = std::ptr::null();

        // SAFETY: All pointers reference live C strings and writable out storage.
        assert_eq!(
            unsafe { gateway_start(config_string.as_ptr(), secrets_string.as_ptr(), &mut error,) },
            0
        );
        assert!(error.is_null());

        // SAFETY: All pointers reference live C strings and writable out storage.
        assert_eq!(
            unsafe { gateway_start(config_string.as_ptr(), secrets_string.as_ptr(), &mut error,) },
            -1
        );
        assert!(take_ffi_string(error).contains("already running"));
        error = std::ptr::null();

        let mut status_json = std::ptr::null();
        // SAFETY: Both out-parameters point to writable storage.
        assert_eq!(unsafe { gateway_status(&mut status_json, &mut error) }, 0);
        let status = take_ffi_string(status_json);
        assert!(error.is_null());
        assert!(!status.contains("super-secret-cloudflare-token"));
        let status: Value = serde_json::from_str(&status).unwrap();
        assert_eq!(status["state"], "running");
        assert_eq!(status["config_generation"], 1);

        config["acme"]["contact_email"] = serde_json::json!("ops@example.com");
        let valid_update = CString::new(config.to_string()).unwrap();
        // SAFETY: The config pointer is valid, null secrets retains current secrets, and the
        // error out-parameter points to writable storage.
        assert_eq!(
            unsafe { gateway_apply_config(valid_update.as_ptr(), std::ptr::null(), &mut error) },
            0
        );
        assert!(error.is_null());
        status_json = std::ptr::null();
        // SAFETY: Both out-parameters point to writable storage.
        assert_eq!(unsafe { gateway_status(&mut status_json, &mut error) }, 0);
        let status: Value = serde_json::from_str(&take_ffi_string(status_json)).unwrap();
        assert_eq!(status["config_generation"], 2);

        config["listeners"]["http"] = serde_json::json!("127.0.0.1:50080");
        let immutable_update = CString::new(config.to_string()).unwrap();
        // SAFETY: The config pointer is valid, null secrets retains current secrets, and the
        // error out-parameter points to writable storage.
        assert_eq!(
            unsafe {
                gateway_apply_config(immutable_update.as_ptr(), std::ptr::null(), &mut error)
            },
            -1
        );
        assert!(take_ffi_string(error).contains("listener changes require"));
        error = std::ptr::null();
        status_json = std::ptr::null();
        // SAFETY: Both out-parameters point to writable storage.
        assert_eq!(unsafe { gateway_status(&mut status_json, &mut error) }, 0);
        let status: Value = serde_json::from_str(&take_ffi_string(status_json)).unwrap();
        assert_eq!(status["config_generation"], 2);

        // Null renewal identifier means all configured certificates (an empty set here).
        // SAFETY: Null is explicitly supported for the optional identifier.
        assert_eq!(
            unsafe { gateway_request_renewal(std::ptr::null(), &mut error) },
            0
        );
        let unknown_certificate = CString::new("missing-cert").unwrap();
        // SAFETY: The identifier is a valid C string and the error slot is writable.
        assert_eq!(
            unsafe { gateway_request_renewal(unknown_certificate.as_ptr(), &mut error) },
            -1
        );
        assert!(take_ffi_string(error).contains("unknown gateway certificate"));
        error = std::ptr::null();

        // SAFETY: The error out-parameter points to writable storage.
        assert_eq!(unsafe { gateway_stop(&mut error) }, 0);
        assert!(error.is_null());
        assert_eq!(unsafe { gateway_stop(&mut error) }, 0);
        assert!(error.is_null());

        // Applying while stopped is rejected and status returns a valid stopped snapshot.
        // SAFETY: The config pointer and error out-parameter are valid.
        assert_eq!(
            unsafe { gateway_apply_config(config_string.as_ptr(), std::ptr::null(), &mut error) },
            -1
        );
        assert!(take_ffi_string(error).contains("gateway is not running"));
        error = std::ptr::null();
        status_json = std::ptr::null();
        // SAFETY: Both out-parameters point to writable storage.
        assert_eq!(unsafe { gateway_status(&mut status_json, &mut error) }, 0);
        let status: Value = serde_json::from_str(&take_ffi_string(status_json)).unwrap();
        assert_eq!(status["state"], "stopped");

        // SAFETY: A null JSON out-parameter is intentionally supplied to exercise validation.
        assert_eq!(
            unsafe { gateway_status(std::ptr::null_mut(), &mut error) },
            -1
        );
        assert!(take_ffi_string(error).contains("out_json must not be null"));
    }

    #[test]
    fn legacy_patch_config_payload_is_adapted_to_easytier_generated_type() {
        let payload = serde_json::json!({
            "patch": {
                "hostname": "edge-mac",
                "port_forwards": [],
                "proxy_networks": [],
                "routes": [],
                "exit_nodes": [],
                "mapped_listeners": [],
                "connectors": []
            },
            "instance": {
                "selector": {
                    "Id": {
                        "part1": 0x11111111u32,
                        "part2": 0x22222222u32,
                        "part3": 0x33333333u32,
                        "part4": 0x44444444u32
                    }
                }
            }
        });
        let request: PatchConfigRequest =
            serde_json::from_value(normalize_instance_identifier_payload(payload)).unwrap();
        assert_eq!(request.patch.unwrap().hostname.as_deref(), Some("edge-mac"));
        let selector = request.instance.unwrap().selector.unwrap();
        assert!(matches!(selector, Selector::Id(_)));
    }

    fn take_ffi_string(pointer: *const c_char) -> String {
        assert!(!pointer.is_null());
        // SAFETY: The pointer is returned by this library and remains valid until free_string.
        let value = unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned();
        // SAFETY: The pointer was allocated by this library and has not been freed yet.
        unsafe { free_string(pointer) };
        value
    }
}
