use std::{
    ffi::{CStr, CString, c_char, c_int},
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use dashmap::DashMap;
use easytier::{
    common::config::{ConfigFileControl, ConfigLoader as _, TomlConfigLoader},
    instance_manager::NetworkInstanceManager,
    proto::{
        api::{
            config::{ConfigRpc, ConfigRpcClientFactory},
            instance::{
                AclManageRpc, AclManageRpcClientFactory, PeerManageRpc, PeerManageRpcClientFactory,
                PortForwardManageRpc, PortForwardManageRpcClientFactory, StatsRpc,
                StatsRpcClientFactory,
            },
            manage::{WebClientService, WebClientServiceClientFactory},
        },
        rpc_impl::standalone::StandAloneClient,
        rpc_types::controller::BaseController,
    },
    rpc_service::ApiRpcServer,
    tunnel::tcp::{TcpTunnelConnector, TcpTunnelListener},
};
use once_cell::sync::Lazy;
use serde_json::Value;
use tokio::{
    runtime::Runtime,
    sync::{OwnedSemaphorePermit, Semaphore},
    time::timeout,
};
use url::{Host, Url};

type RpcPortalServer = ApiRpcServer<TcpTunnelListener>;

static INSTANCE_NAME_ID_MAP: Lazy<DashMap<String, uuid::Uuid>> = Lazy::new(DashMap::new);
static INSTANCE_MANAGER: Lazy<Arc<NetworkInstanceManager>> =
    Lazy::new(|| Arc::new(NetworkInstanceManager::new()));
static RPC_CLIENTS: Lazy<DashMap<String, Arc<RpcEndpoint>>> = Lazy::new(DashMap::new);
static RPC_PORTAL_SERVER: Lazy<Mutex<Option<RpcPortalServer>>> = Lazy::new(|| Mutex::new(None));
static RPC_RUNTIME: Lazy<Runtime> =
    Lazy::new(|| Runtime::new().expect("failed to create EasyTier RPC runtime"));
static RPC_TOTAL_LIMIT: Lazy<Arc<Semaphore>> =
    Lazy::new(|| Arc::new(Semaphore::new(RPC_MAX_CONCURRENT_TOTAL)));
static RPC_CONNECTING_LIMIT: Lazy<Arc<Semaphore>> =
    Lazy::new(|| Arc::new(Semaphore::new(RPC_MAX_CONNECTING_TOTAL)));
const RPC_CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
const RPC_CALL_TIMEOUT: Duration = Duration::from_secs(8);
const RPC_QUEUE_TIMEOUT: Duration = Duration::from_secs(2);
const RPC_UNAVAILABLE_COOLDOWN: Duration = Duration::from_secs(5);
const RPC_MAX_CONCURRENT_PER_ENDPOINT: usize = 4;
const RPC_MAX_CONCURRENT_TOTAL: usize = 32;
const RPC_MAX_CONNECTING_TOTAL: usize = 8;

static ERROR_MSG: Lazy<Mutex<Vec<u8>>> = Lazy::new(|| Mutex::new(Vec::new()));

struct RpcEndpoint {
    url: String,
    limit: Arc<Semaphore>,
    state: Mutex<RpcEndpointState>,
    /// Persistent `StandAloneClient` reused across `call_json_rpc` invocations so that
    /// TCP connections are kept alive between calls instead of being re-established.
    /// Guarded by a tokio mutex because `scoped_client` is async and needs `&mut self`.
    client: tokio::sync::Mutex<StandAloneClient<TcpTunnelConnector>>,
}

#[derive(Default)]
struct RpcEndpointState {
    cooldown_until: Option<Instant>,
    last_error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RpcFailureKind {
    ConnectUnavailable,
    ConnectTimeout,
    QueueFull,
    RequestTimeout,
    RpcError,
}

#[derive(Debug)]
struct RpcCallError {
    #[allow(dead_code)]
    kind: RpcFailureKind,
    message: String,
}

impl RpcCallError {
    fn new(kind: RpcFailureKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }
}

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
        let cstr = CString::new(sanitized.as_bytes())
            .unwrap_or_else(|_| CString::new("EasyTier FFI error contained an invalid NUL byte").unwrap());
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

fn is_allowed_rpc_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(addr) => is_allowed_ipv4(addr),
        IpAddr::V6(addr) => is_allowed_ipv6(addr),
    }
}

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

fn is_allowed_ipv6(addr: Ipv6Addr) -> bool {
    let first = addr.segments()[0];
    addr.is_loopback() || (first & 0xfe00) == 0xfc00 || (first & 0xffc0) == 0xfe80
}

fn is_allowed_service_method(service_name: &str, method_name: &str) -> bool {
    match service_name {
        "api.config.ConfigRpcService" => matches!(
            method_name,
            "patch_config" | "PatchConfig" | "get_config" | "GetConfig"
        ),
        "api.instance.PeerManageRpcService" => matches!(
            method_name,
            "list_peer"
                | "ListPeer"
                | "list_public_ipv6_info"
                | "ListPublicIpv6Info"
                | "list_route"
                | "ListRoute"
                | "dump_route"
                | "DumpRoute"
                | "list_foreign_network"
                | "ListForeignNetwork"
                | "list_global_foreign_network"
                | "ListGlobalForeignNetwork"
                | "show_node_info"
                | "ShowNodeInfo"
                | "get_foreign_network_summary"
                | "GetForeignNetworkSummary"
        ),
        "api.instance.StatsRpcService" => matches!(
            method_name,
            "get_stats" | "GetStats" | "get_prometheus_stats" | "GetPrometheusStats"
        ),
        "api.instance.AclManageRpcService" => matches!(
            method_name,
            "get_acl_stats" | "GetAclStats" | "get_whitelist" | "GetWhitelist"
        ),
        "api.instance.PortForwardManageRpcService" => {
            matches!(method_name, "list_port_forward" | "ListPortForward")
        }
        "api.manage.WebClientService" => {
            matches!(method_name, "run_network_instance" | "RunNetworkInstance")
        }
        _ => false,
    }
}

async fn acquire_rpc_permit(
    semaphore: Arc<Semaphore>,
    label: &str,
    wait: Duration,
) -> Result<OwnedSemaphorePermit, RpcCallError> {
    timeout(wait, semaphore.acquire_owned())
        .await
        .map_err(|_| {
            RpcCallError::new(
                RpcFailureKind::QueueFull,
                format!("EasyTier RPC is busy waiting for {label} capacity. Try again shortly."),
            )
        })?
        .map_err(|_| {
            RpcCallError::new(
                RpcFailureKind::QueueFull,
                format!("EasyTier RPC {label} limiter is closed."),
            )
        })
}

async fn call_rpc_by_service(
    endpoint: Arc<RpcEndpoint>,
    service_name: &str,
    method_name: &str,
    domain: String,
    payload: Value,
) -> Result<Value, RpcCallError> {
    endpoint
        .check_cooldown()
        .map_err(|e| RpcCallError::new(RpcFailureKind::ConnectUnavailable, e))?;
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
                    return Err(RpcCallError::new(
                        RpcFailureKind::ConnectUnavailable,
                        message,
                    ));
                }
                Err(_) => {
                    drop(connect_permit);
                    let message = format!(
                        "Remote EasyTier RPC connect timed out after {} seconds.",
                        RPC_CONNECT_TIMEOUT.as_secs()
                    );
                    endpoint.set_connect_cooldown(message.clone());
                    return Err(RpcCallError::new(RpcFailureKind::ConnectTimeout, message));
                }
            };

            match timeout(
                RPC_CALL_TIMEOUT,
                stub.json_call_method(BaseController::default(), method_name, payload),
            )
            .await
            {
                Ok(Ok(value)) => Ok(value),
                Ok(Err(e)) => Err(RpcCallError::new(
                    RpcFailureKind::RpcError,
                    format!("RPC Error: {e:?}"),
                )),
                Err(_) => Err(RpcCallError::new(
                    RpcFailureKind::RequestTimeout,
                    format!(
                        "EasyTier RPC request timed out after {} seconds.",
                        RPC_CALL_TIMEOUT.as_secs()
                    ),
                )),
            }
        }};
    }

    match service_name {
        "api.config.ConfigRpcService" => {
            call_service!(ConfigRpcClientFactory<BaseController>)
        }
        "api.instance.PeerManageRpcService" => {
            call_service!(PeerManageRpcClientFactory<BaseController>)
        }
        "api.instance.StatsRpcService" => {
            call_service!(StatsRpcClientFactory<BaseController>)
        }
        "api.instance.AclManageRpcService" => {
            call_service!(AclManageRpcClientFactory<BaseController>)
        }
        "api.instance.PortForwardManageRpcService" => {
            call_service!(PortForwardManageRpcClientFactory<BaseController>)
        }
        "api.manage.WebClientService" => {
            call_service!(WebClientServiceClientFactory<BaseController>)
        }
        _ => Err(RpcCallError::new(
            RpcFailureKind::RpcError,
            format!("Unknown service: {service_name}"),
        )),
    }
}

/// # Safety
/// `out` must point to writable storage for one C string pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn get_error_msg(out: *mut *const c_char) {
    if out.is_null() {
        return;
    }

    let mut msg_buf = ERROR_MSG.lock().unwrap();
    if msg_buf.is_empty() {
        // SAFETY: `out` was checked for null and points to caller-owned storage.
        unsafe {
            *out = std::ptr::null();
        }
        return;
    }

    let cstr = CString::new(msg_buf.as_slice()).unwrap_or_else(|_| {
        CString::new("EasyTier FFI error contained an invalid NUL byte").unwrap()
    });
    msg_buf.clear();
    // SAFETY: `out` was checked for null and points to caller-owned storage.
    unsafe {
        *out = cstr.into_raw();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn free_string(s: *const c_char) {
    if s.is_null() {
        return;
    }
    // SAFETY: Callers must only pass pointers returned by this library via CString::into_raw.
    unsafe {
        let _ = CString::from_raw(s as *mut c_char);
    }
}

/// # Safety
/// `cfg_str` must be a valid NUL-terminated C string pointer.
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null.
#[unsafe(no_mangle)]
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
                    INSTANCE_MANAGER
                        .run_network_instance(cfg, true, ConfigFileControl::STATIC_CONFIG)
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
pub unsafe extern "C" fn retain_network_instance(
    inst_names: *const *const c_char,
    length: usize,
    out_error: *mut *const c_char,
) -> c_int {
    // SAFETY: `out_error` is caller-owned storage or null.
    unsafe {
        ffi_result_with_error(out_error, || {
            if length == 0 {
                INSTANCE_MANAGER
                    .retain_network_instance(Vec::new())
                    .map_err(|e| format!("failed to retain instances: {e}"))?;
                INSTANCE_NAME_ID_MAP.clear();
                return Ok(());
            }

            if inst_names.is_null() {
                return Err("inst_names must not be null when length is greater than zero".to_string());
            }
            // SAFETY: `inst_names` is checked for null and caller promises `length` valid entries.
            let inst_names = std::slice::from_raw_parts(inst_names, length)
                .iter()
                .enumerate()
                .map(|(index, &name)| {
                    // SAFETY: Each entry is a caller-owned C string pointer; null/UTF-8 are checked.
                    cstr_arg(name, &format!("inst_names[{index}]"))
                })
                .collect::<Result<Vec<_>, _>>()?;

            let mut inst_ids: Vec<uuid::Uuid> = inst_names
                .iter()
                .filter_map(|name| INSTANCE_NAME_ID_MAP.get(name).map(|id| *id))
                .collect();
            inst_ids.reverse();

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
pub unsafe extern "C" fn stop_network_instance(
    inst_names: *const *const c_char,
    length: usize,
    out_error: *mut *const c_char,
) -> c_int {
    // SAFETY: `out_error` is caller-owned storage or null.
    unsafe {
        ffi_result_with_error(out_error, || {
            if length == 0 {
                return Ok(());
            }
            if inst_names.is_null() {
                return Err("inst_names must not be null when length is greater than zero".to_string());
            }
            // SAFETY: `inst_names` is checked for null and caller promises `length` valid entries.
            let inst_names = std::slice::from_raw_parts(inst_names, length)
                .iter()
                .enumerate()
                .map(|(index, &name)| {
                    // SAFETY: Each entry is a caller-owned C string pointer; null/UTF-8 are checked.
                    cstr_arg(name, &format!("inst_names[{index}]"))
                })
                .collect::<Result<Vec<_>, _>>()?;

            let mut inst_ids: Vec<uuid::Uuid> = inst_names
                .iter()
                .filter_map(|name| INSTANCE_NAME_ID_MAP.get(name).map(|id| *id))
                .collect();
            inst_ids.reverse();

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

        let mut index = 0;
        for (instance_id, value) in collected_infos.iter() {
            if index >= max_length {
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
                obj.insert("instance_id".to_string(), serde_json::Value::String(instance_id.to_string()));
            }
            let value = serde_json::to_string(&json_value)
                .map_err(|e| format!("failed to serialize instance info: {e}"))?;

            infos[index] = KeyValuePair {
                key: CString::new(key)
                    .map_err(|e| format!("instance name contained a NUL byte: {e}"))?
                    .into_raw(),
                value: CString::new(value)
                    .map_err(|e| format!("instance info contained a NUL byte: {e}"))?
                    .into_raw(),
            };
            index += 1;
        }

        Ok(index as c_int)
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
                    "whitelist must not be null when whitelist_count is greater than zero".to_string(),
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
                            .map_err(|e| format!("invalid RPC portal whitelist entry #{index}: {e}"))
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                Some(values)
            };

            let server = RPC_RUNTIME.block_on(async {
                let server = ApiRpcServer::new(Some(listen_addr), whitelist, INSTANCE_MANAGER.clone())
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
/// `client_id` must be a valid NUL-terminated C string pointer.
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn disconnect_rpc_client(
    client_id: *const c_char,
    out_error: *mut *const c_char,
) -> c_int {
    // SAFETY: `out_error` is caller-owned storage or null.
    unsafe {
        ffi_result_with_error(out_error, || {
            // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
            let client_id = cstr_arg(client_id, "client_id")?;
            disconnect_rpc_client_inner(&client_id);
            Ok(())
        })
    }
}

fn disconnect_rpc_client_inner(client_id: &str) {
    RPC_CLIENTS.remove(client_id);
}

/// # Safety
/// String pointers must be valid NUL-terminated C strings. `out_json` must point to writable
/// storage for one C string pointer and must be released by calling `free_string`.
/// `out_error` must point to caller-owned storage for one `*const c_char`, or be null;
/// on failure it owns a `CString` that must be released with `free_string`.
#[unsafe(no_mangle)]
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

fn call_json_rpc_inner(
    client_id: String,
    service_name: String,
    method_name: String,
    domain: String,
    payload_json: String,
) -> Result<String, String> {
    let payload = serde_json::from_str::<Value>(&payload_json)
        .map_err(|e| format!("payload_json must be valid JSON: {e}"))?;

    if !is_allowed_service_method(&service_name, &method_name) {
        return Err(format!(
            "RPC service or method is not allowed: {service_name}.{method_name}"
        ));
    }

    let endpoint = RPC_CLIENTS
        .get(&client_id)
        .map(|entry| Arc::clone(entry.value()))
        .ok_or_else(|| format!("RPC client is not connected: {client_id}"))?;
    endpoint.check_cooldown()?;

    let response = RPC_RUNTIME
        .block_on(call_rpc_by_service(
            endpoint,
            &service_name,
            &method_name,
            domain,
            payload,
        ))
        .map_err(|e| e.message)?;
    serde_json::to_string(&response).map_err(|e| format!("failed to serialize RPC response: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use easytier::proto::api::{
        config::PatchConfigRequest,
        instance::{ListPeerRequest, instance_identifier::Selector},
        manage::RunNetworkInstanceRequest,
    };

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
            "GetConfig"
        ));
        assert!(is_allowed_service_method(
            "api.instance.PeerManageRpcService",
            "list_peer"
        ));
        assert!(is_allowed_service_method(
            "api.manage.WebClientService",
            "run_network_instance"
        ));
        assert!(!is_allowed_service_method(
            "api.manage.WebClientService",
            "list_network_instance"
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
        disconnect_rpc_client_inner(&client_id);
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

            assert_eq!(error.kind, RpcFailureKind::QueueFull);
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
        free_string(error);

        // Success path should clear the out-error slot.
        let valid_cfg = "instance_name = \"t\"\nnetwork_name = \"n\"\n";
        let mut error2: *const c_char = std::ptr::null();
        // SAFETY: `valid_cfg` is a valid NUL-terminated C string; `error2` is valid storage.
        let result2 = unsafe {
            parse_config(
                CString::new(valid_cfg).unwrap().as_ptr(),
                &mut error2,
            )
        };
        assert_eq!(result2, 0);
        assert!(error2.is_null());
    }

    #[test]
    fn rpc_payload_shape_matches_easytier_generated_types() {
        let payload = serde_json::json!({
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
        let request: ListPeerRequest = serde_json::from_value(payload).unwrap();
        let selector = request.instance.unwrap().selector.unwrap();
        assert!(matches!(selector, Selector::Id(_)));

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
        let request: PatchConfigRequest = serde_json::from_value(payload).unwrap();
        assert_eq!(request.patch.unwrap().hostname.as_deref(), Some("edge-mac"));
        let selector = request.instance.unwrap().selector.unwrap();
        assert!(matches!(selector, Selector::Id(_)));

        let payload = serde_json::json!({
            "inst_id": {
                "part1": 0x11111111u32,
                "part2": 0x22222222u32,
                "part3": 0x33333333u32,
                "part4": 0x44444444u32
            },
            "config": {
                "hostname": "edge-mac",
                "network_name": "office"
            },
            "overwrite": true,
            "source": 1
        });
        let request: RunNetworkInstanceRequest = serde_json::from_value(payload).unwrap();
        assert_eq!(
            request.config.unwrap().hostname.as_deref(),
            Some("edge-mac")
        );
        assert!(request.overwrite);
    }
}
