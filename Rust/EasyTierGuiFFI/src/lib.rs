use std::{
    ffi::{CStr, CString, c_char, c_int},
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    sync::Mutex,
};

use anyhow::{Context, anyhow};
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
        },
        rpc_impl::standalone::StandAloneClient,
        rpc_types::controller::BaseController,
    },
    tunnel::tcp::TcpTunnelConnector,
};
use once_cell::sync::Lazy;
use serde_json::Value;
use tokio::runtime::Runtime;
use url::{Host, Url};

type RpcClient = StandAloneClient<TcpTunnelConnector>;

static INSTANCE_NAME_ID_MAP: Lazy<DashMap<String, uuid::Uuid>> = Lazy::new(DashMap::new);
static INSTANCE_MANAGER: Lazy<NetworkInstanceManager> = Lazy::new(NetworkInstanceManager::new);
static RPC_CLIENTS: Lazy<DashMap<String, RpcClientEntry>> = Lazy::new(DashMap::new);
static RPC_RUNTIME: Lazy<Runtime> =
    Lazy::new(|| Runtime::new().expect("failed to create EasyTier RPC runtime"));

static ERROR_MSG: Lazy<Mutex<Vec<u8>>> = Lazy::new(|| Mutex::new(Vec::new()));

struct RpcClientEntry {
    url: String,
    client: Mutex<RpcClient>,
}

#[repr(C)]
pub struct KeyValuePair {
    pub key: *const c_char,
    pub value: *const c_char,
}

fn set_error_msg(msg: &str) {
    let sanitized = msg.replace('\0', "\\0");
    let bytes = sanitized.as_bytes();
    let mut msg_buf = ERROR_MSG.lock().unwrap();
    msg_buf.resize(bytes.len(), 0);
    msg_buf[..].copy_from_slice(bytes);
}

fn clear_error_msg() {
    ERROR_MSG.lock().unwrap().clear();
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

fn ffi_result<T>(operation: impl FnOnce() -> Result<T, String>) -> c_int {
    match operation() {
        Ok(_) => {
            clear_error_msg();
            0
        }
        Err(error) => {
            set_error_msg(&error);
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
        _ => false,
    }
}

async fn call_rpc_by_service(
    client: &mut RpcClient,
    service_name: &str,
    method_name: &str,
    domain: String,
    payload: Value,
) -> anyhow::Result<Value> {
    macro_rules! call_service {
        ($factory:ty) => {{
            let stub = client
                .scoped_client::<$factory>(domain)
                .await
                .with_context(|| "failed to create scoped EasyTier RPC client")?;
            stub.json_call_method(BaseController::default(), method_name, payload)
                .await
                .map_err(|e| anyhow!("RPC Error: {e:?}"))
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
        _ => Err(anyhow!("Unknown service: {service_name}")),
    }
}

/// # Safety
/// `inst_name` must be a valid NUL-terminated C string pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn set_tun_fd(inst_name: *const c_char, fd: c_int) -> c_int {
    ffi_result(|| {
        // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
        let inst_name = unsafe { cstr_arg(inst_name, "inst_name") }?;
        if !INSTANCE_NAME_ID_MAP.contains_key(&inst_name) {
            return Err("instance does not exist".to_string());
        }

        let inst_id = *INSTANCE_NAME_ID_MAP
            .get(&inst_name)
            .as_ref()
            .unwrap()
            .value();

        INSTANCE_MANAGER
            .set_tun_fd(&inst_id, fd)
            .map_err(|e| format!("failed to set TUN fd: {e}"))
    })
}

/// # Safety
/// `out` must point to writable storage for one C string pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn get_error_msg(out: *mut *const c_char) {
    if out.is_null() {
        return;
    }

    let msg_buf = ERROR_MSG.lock().unwrap();
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
#[unsafe(no_mangle)]
pub unsafe extern "C" fn parse_config(cfg_str: *const c_char) -> c_int {
    ffi_result(|| {
        // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
        let cfg_str = unsafe { cstr_arg(cfg_str, "cfg_str") }?;
        TomlConfigLoader::new_from_str(&cfg_str)
            .map(|_| ())
            .map_err(|e| format!("failed to parse config: {e:?}"))
    })
}

/// # Safety
/// `cfg_str` must be a valid NUL-terminated C string pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn run_network_instance(cfg_str: *const c_char) -> c_int {
    ffi_result(|| {
        // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
        let cfg_str = unsafe { cstr_arg(cfg_str, "cfg_str") }?;
        let cfg = TomlConfigLoader::new_from_str(&cfg_str)
            .map_err(|e| format!("failed to parse config: {e}"))?;

        let inst_name = cfg.get_inst_name();
        if INSTANCE_NAME_ID_MAP.contains_key(&inst_name) {
            return Err("instance already exists".to_string());
        }

        let instance_id = INSTANCE_MANAGER
            .run_network_instance(cfg, false, ConfigFileControl::STATIC_CONFIG)
            .map_err(|e| format!("failed to start instance: {e}"))?;

        INSTANCE_NAME_ID_MAP.insert(inst_name, instance_id);
        Ok(())
    })
}

/// # Safety
/// When `length > 0`, `inst_names` must point to an array of valid NUL-terminated C strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn retain_network_instance(
    inst_names: *const *const c_char,
    length: usize,
) -> c_int {
    ffi_result(|| {
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
        let inst_names = unsafe { std::slice::from_raw_parts(inst_names, length) }
            .iter()
            .enumerate()
            .map(|(index, &name)| {
                // SAFETY: Each entry is a caller-owned C string pointer; null/UTF-8 are checked.
                unsafe { cstr_arg(name, &format!("inst_names[{index}]")) }
            })
            .collect::<Result<Vec<_>, _>>()?;

        let inst_ids: Vec<uuid::Uuid> = inst_names
            .iter()
            .filter_map(|name| INSTANCE_NAME_ID_MAP.get(name).map(|id| *id))
            .collect();

        INSTANCE_MANAGER
            .retain_network_instance(inst_ids)
            .map_err(|e| format!("failed to retain instances: {e}"))?;
        INSTANCE_NAME_ID_MAP.retain(|k, _| inst_names.contains(k));
        Ok(())
    })
}

/// # Safety
/// `infos` must point to writable storage for `max_length` `KeyValuePair` values.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn collect_network_infos(
    infos: *mut KeyValuePair,
    max_length: usize,
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

        let collected_infos = INSTANCE_MANAGER
            .collect_network_infos_sync()
            .map_err(|e| format!("failed to collect network infos: {e}"))?;

        let mut index = 0;
        for (instance_id, value) in collected_infos.iter() {
            if index >= max_length {
                break;
            }
            let Some(key) = INSTANCE_MANAGER.get_instance_name(instance_id) else {
                continue;
            };
            let value = serde_json::to_string(&value)
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
            clear_error_msg();
            count
        }
        Err(error) => {
            set_error_msg(&error);
            -1
        }
    }
}

/// # Safety
/// `client_id` and `url` must be valid NUL-terminated C string pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn connect_rpc_client(client_id: *const c_char, url: *const c_char) -> c_int {
    ffi_result(|| {
        // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
        let client_id = unsafe { cstr_arg(client_id, "client_id") }?;
        // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
        let url_string = unsafe { cstr_arg(url, "url") }?;
        if client_id.trim().is_empty() {
            return Err("client_id must not be empty".to_string());
        }
        let url = validate_rpc_url(&url_string)?;

        let should_replace = RPC_CLIENTS
            .get(&client_id)
            .is_none_or(|entry| entry.url != url_string);
        if should_replace {
            RPC_CLIENTS.insert(
                client_id,
                RpcClientEntry {
                    url: url_string,
                    client: Mutex::new(StandAloneClient::new(TcpTunnelConnector::new(url))),
                },
            );
        }
        Ok(())
    })
}

/// # Safety
/// `client_id` must be a valid NUL-terminated C string pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn disconnect_rpc_client(client_id: *const c_char) -> c_int {
    ffi_result(|| {
        // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
        let client_id = unsafe { cstr_arg(client_id, "client_id") }?;
        RPC_CLIENTS.remove(&client_id);
        Ok(())
    })
}

/// # Safety
/// String pointers must be valid NUL-terminated C strings. `out_json` must point to writable
/// storage for one C string pointer and must be released by calling `free_string`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn call_json_rpc(
    client_id: *const c_char,
    service_name: *const c_char,
    method_name: *const c_char,
    domain: *const c_char,
    payload_json: *const c_char,
    out_json: *mut *const c_char,
) -> c_int {
    ffi_result(|| {
        if !out_json.is_null() {
            // SAFETY: `out_json` was checked for null and points to caller-owned storage.
            unsafe {
                *out_json = std::ptr::null();
            }
        }

        // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
        let client_id = unsafe { cstr_arg(client_id, "client_id") }?;
        // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
        let service_name = unsafe { cstr_arg(service_name, "service_name") }?;
        // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
        let method_name = unsafe { cstr_arg(method_name, "method_name") }?;
        let domain = if domain.is_null() {
            String::new()
        } else {
            // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
            unsafe { cstr_arg(domain, "domain") }?
        };
        // SAFETY: The C ABI caller owns pointer validity; null/UTF-8 are checked here.
        let payload_json = unsafe { cstr_arg(payload_json, "payload_json") }?;
        let payload = serde_json::from_str::<Value>(&payload_json)
            .map_err(|e| format!("payload_json must be valid JSON: {e}"))?;

        if !is_allowed_service_method(&service_name, &method_name) {
            return Err(format!(
                "RPC service or method is not allowed: {service_name}.{method_name}"
            ));
        }

        let entry = RPC_CLIENTS
            .get(&client_id)
            .ok_or_else(|| format!("RPC client is not connected: {client_id}"))?;
        let mut client = entry
            .client
            .lock()
            .map_err(|_| "RPC client lock is poisoned".to_string())?;

        let response = RPC_RUNTIME
            .block_on(call_rpc_by_service(
                &mut client,
                &service_name,
                &method_name,
                domain,
                payload,
            ))
            .map_err(|e| {
                RPC_CLIENTS.remove(&client_id);
                e.to_string()
            })?;
        let response_json = serde_json::to_string(&response)
            .map_err(|e| format!("failed to serialize RPC response: {e}"))?;
        write_cstring_out(response_json, out_json)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use easytier::proto::api::{
        config::PatchConfigRequest,
        instance::{ListPeerRequest, instance_identifier::Selector},
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
    fn c_abi_null_pointer_returns_error() {
        // SAFETY: This intentionally passes a null pointer to exercise the FFI guard.
        let result = unsafe { parse_config(std::ptr::null()) };
        assert_eq!(result, -1);

        let mut error: *const c_char = std::ptr::null();
        // SAFETY: `error` is valid writable storage for one pointer.
        unsafe { get_error_msg(&mut error) };
        assert!(!error.is_null());
        let message = unsafe { CStr::from_ptr(error) }.to_string_lossy();
        assert!(message.contains("cfg_str must not be null"));
        free_string(error);
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
    }
}
