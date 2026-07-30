use std::{
    collections::{HashMap, HashSet},
    ffi::{CString, c_char, c_int, c_void},
    sync::{
        Arc, LazyLock, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};

use easytier::{
    common::{
        MachineIdOptions,
        config::{ConfigLoader as _, TomlConfigLoader},
    },
    tunnel::TunnelScheme,
    web_client::{WebClient, WebClientHooks, run_web_client},
};
use serde_json::json;
use url::Url;
use uuid::Uuid;

use crate::{
    INSTANCE_MANAGER, INSTANCE_MUTATION_LOCK, INSTANCE_NAME_ID_MAP, RPC_RUNTIME, cstr_arg,
    ffi_result_with_error,
};

pub type ConfigServerEventCallback = Option<unsafe extern "C" fn(*const c_char, *mut c_void)>;

static CONFIG_SERVER_CLIENT: LazyLock<Mutex<Option<ManagedConfigServerClient>>> =
    LazyLock::new(|| Mutex::new(None));
static CONFIG_SERVER_ACTIVE: AtomicBool = AtomicBool::new(false);
static CONFIG_SERVER_STOPPING: AtomicBool = AtomicBool::new(false);

struct ManagedConfigServerClient {
    client: WebClient,
    hooks: Arc<ManagedConfigServerHooks>,
}

#[derive(Clone)]
struct InstanceMetadata {
    instance_name: String,
    network_name: String,
    magic_dns_enabled: bool,
    magic_dns_suffix: String,
}

struct ManagedConfigServerHooks {
    instance_ids: Mutex<HashSet<Uuid>>,
    metadata: Mutex<HashMap<Uuid, InstanceMetadata>>,
    callback_delivery: Mutex<()>,
    stopping: AtomicBool,
    callback: ConfigServerEventCallback,
    user_data: usize,
}

impl ManagedConfigServerHooks {
    fn new(callback: ConfigServerEventCallback, user_data: *mut c_void) -> Self {
        Self {
            instance_ids: Mutex::new(HashSet::new()),
            metadata: Mutex::new(HashMap::new()),
            callback_delivery: Mutex::new(()),
            stopping: AtomicBool::new(false),
            callback,
            user_data: user_data as usize,
        }
    }

    fn validate_instance_name(&self, name: &str, id: Uuid) -> Result<(), String> {
        if let Some(existing_id) = INSTANCE_NAME_ID_MAP.get(name).map(|entry| *entry)
            && existing_id != id
        {
            return Err(format!("instance name {name} already exists"));
        }
        Ok(())
    }

    fn start_stopping(&self) -> Vec<Uuid> {
        let _delivery = self.callback_delivery.lock().ok();
        self.stopping.store(true, Ordering::Release);
        self.metadata.lock().map(|mut value| value.clear()).ok();
        self.instance_ids
            .lock()
            .map(|mut ids| ids.drain().collect())
            .unwrap_or_default()
    }

    fn emit(&self, event: &str, id: Uuid, metadata: Option<InstanceMetadata>) {
        if self.stopping.load(Ordering::Acquire) {
            return;
        }
        let Some(callback) = self.callback else {
            return;
        };
        let Ok(_delivery) = self.callback_delivery.lock() else {
            return;
        };
        let metadata = metadata.unwrap_or(InstanceMetadata {
            instance_name: String::new(),
            network_name: String::new(),
            magic_dns_enabled: false,
            magic_dns_suffix: String::new(),
        });
        let payload = json!({
            "event": event,
            "instance_id": id.to_string(),
            "instance_name": metadata.instance_name,
            "network_name": metadata.network_name,
            "magic_dns_enabled": metadata.magic_dns_enabled,
            "magic_dns_suffix": metadata.magic_dns_suffix,
        })
        .to_string();
        let Ok(payload) = CString::new(payload) else {
            return;
        };
        unsafe { callback(payload.as_ptr(), self.user_data as *mut c_void) };
    }

    fn wait_for_delivery(&self) {
        if let Ok(delivery) = self.callback_delivery.lock() {
            drop(delivery);
        }
    }
}

#[async_trait::async_trait]
impl WebClientHooks for ManagedConfigServerHooks {
    async fn pre_run_network_instance(&self, config: &TomlConfigLoader) -> Result<(), String> {
        if self.stopping.load(Ordering::Acquire) {
            return Err("config server client is stopping".to_string());
        }
        let id = config.get_id();
        let instance_name = config.get_inst_name();
        self.validate_instance_name(&instance_name, id)?;
        let flags = config.get_flags();
        let metadata = InstanceMetadata {
            instance_name,
            network_name: config.get_network_identity().network_name,
            magic_dns_enabled: flags.accept_dns,
            magic_dns_suffix: flags.tld_dns_zone,
        };
        self.metadata
            .lock()
            .map_err(|error| error.to_string())?
            .insert(id, metadata);
        Ok(())
    }

    async fn post_run_network_instance(&self, id: &Uuid) -> Result<(), String> {
        let _mutation = INSTANCE_MUTATION_LOCK
            .lock()
            .map_err(|error| error.to_string())?;
        if self.stopping.load(Ordering::Acquire) {
            INSTANCE_MANAGER
                .delete_network_instance(vec![*id])
                .map_err(|error| error.to_string())?;
            self.metadata.lock().map(|mut value| value.remove(id)).ok();
            return Ok(());
        }
        let metadata = self
            .metadata
            .lock()
            .map_err(|error| error.to_string())?
            .get(id)
            .cloned()
            .ok_or_else(|| format!("missing config server metadata for instance {id}"))?;
        self.validate_instance_name(&metadata.instance_name, *id)?;
        INSTANCE_NAME_ID_MAP.retain(|_, existing_id| *existing_id != *id);
        INSTANCE_NAME_ID_MAP.insert(metadata.instance_name.clone(), *id);
        self.instance_ids
            .lock()
            .map_err(|error| error.to_string())?
            .insert(*id);
        drop(_mutation);
        self.emit("run_network_instance", *id, Some(metadata));
        Ok(())
    }

    async fn post_remove_network_instances(&self, ids: &[Uuid]) -> Result<(), String> {
        let removed = {
            let _mutation = INSTANCE_MUTATION_LOCK
                .lock()
                .map_err(|error| error.to_string())?;
            let mut tracked = self
                .instance_ids
                .lock()
                .map_err(|error| error.to_string())?;
            let mut metadata = self.metadata.lock().map_err(|error| error.to_string())?;
            let removed = ids
                .iter()
                .filter_map(|id| tracked.remove(id).then(|| (*id, metadata.remove(id))))
                .collect::<Vec<_>>();
            INSTANCE_NAME_ID_MAP.retain(|_, existing_id| !ids.contains(existing_id));
            removed
        };
        for (id, metadata) in removed {
            self.emit("delete_network_instance", id, metadata);
        }
        Ok(())
    }
}

fn build_config_server_url(endpoint: &str, token: &str) -> Result<String, String> {
    if token.is_empty() {
        return Err("config server token is empty".to_string());
    }
    let mut url =
        Url::parse(endpoint).map_err(|error| format!("invalid config server endpoint: {error}"))?;
    TunnelScheme::try_from(&url)
        .map_err(|_| format!("unsupported config server scheme: {}", url.scheme()))?;
    if !url.username().is_empty() || url.password().is_some() {
        return Err("config server endpoint must not contain user information".to_string());
    }
    if url.query().is_some() || url.fragment().is_some() {
        return Err("config server endpoint must not contain a query or fragment".to_string());
    }
    let mut segments = url
        .path_segments_mut()
        .map_err(|_| "config server endpoint cannot contain path segments".to_string())?;
    segments.pop_if_empty();
    segments.push(token);
    drop(segments);
    Ok(url.to_string())
}

pub fn is_active() -> bool {
    CONFIG_SERVER_ACTIVE.load(Ordering::Acquire)
}

/// # Safety
/// All string pointers must be valid NUL-terminated UTF-8 strings. `user_data`
/// must remain valid for callback delivery until stop returns.
pub unsafe fn start(
    endpoint: *const c_char,
    token: *const c_char,
    device_name: *const c_char,
    machine_id: *const c_char,
    secure_required: c_int,
    callback: ConfigServerEventCallback,
    user_data: *mut c_void,
) -> Result<(), String> {
    let endpoint = unsafe { cstr_arg(endpoint, "endpoint") }?;
    let token = unsafe { cstr_arg(token, "token") }?;
    let device_name = unsafe { cstr_arg(device_name, "device_name") }?;
    let machine_id = unsafe { cstr_arg(machine_id, "machine_id") }?;
    Uuid::parse_str(&machine_id).map_err(|error| format!("invalid machine ID: {error}"))?;
    let config_server_url = build_config_server_url(&endpoint, &token)?;

    let mut client = CONFIG_SERVER_CLIENT
        .lock()
        .map_err(|error| error.to_string())?;
    if client.is_some() || CONFIG_SERVER_STOPPING.load(Ordering::Acquire) {
        return Err("config server client is already active or stopping".to_string());
    }
    let _mutation = INSTANCE_MUTATION_LOCK
        .lock()
        .map_err(|error| error.to_string())?;
    if !INSTANCE_MANAGER.list_network_instance_ids().is_empty() {
        return Err(
            "local network instances must be stopped before remote mode starts".to_string(),
        );
    }

    CONFIG_SERVER_ACTIVE.store(true, Ordering::Release);
    let hooks = Arc::new(ManagedConfigServerHooks::new(callback, user_data));
    let web_client = RPC_RUNTIME.block_on(run_web_client(
        &config_server_url,
        MachineIdOptions {
            explicit_machine_id: Some(machine_id),
            state_dir: None,
        },
        Some(device_name),
        secure_required != 0,
        INSTANCE_MANAGER.clone(),
        Some(hooks.clone()),
    ));
    match web_client {
        Ok(web_client) => {
            *client = Some(ManagedConfigServerClient {
                client: web_client,
                hooks,
            });
            Ok(())
        }
        Err(error) => {
            CONFIG_SERVER_ACTIVE.store(false, Ordering::Release);
            Err(format!("failed to start config server client: {error}"))
        }
    }
}

pub fn stop() -> Result<(), String> {
    let mut client = CONFIG_SERVER_CLIENT
        .lock()
        .map_err(|error| error.to_string())?;
    let Some(managed) = client.take() else {
        CONFIG_SERVER_ACTIVE.store(false, Ordering::Release);
        return Ok(());
    };
    if CONFIG_SERVER_STOPPING.swap(true, Ordering::AcqRel) {
        *client = Some(managed);
        return Err("config server client is already stopping".to_string());
    }
    drop(client);
    let ids = managed.hooks.start_stopping();
    drop(managed.client);
    let result = {
        let _mutation = INSTANCE_MUTATION_LOCK
            .lock()
            .map_err(|error| error.to_string())?;
        let result = INSTANCE_MANAGER
            .delete_network_instance(ids.clone())
            .map(|_| ())
            .map_err(|error| format!("failed to delete remote instances: {error}"));
        if result.is_ok() {
            INSTANCE_NAME_ID_MAP.retain(|_, instance_id| !ids.contains(instance_id));
        }
        result
    };
    managed.hooks.wait_for_delivery();
    CONFIG_SERVER_ACTIVE.store(false, Ordering::Release);
    CONFIG_SERVER_STOPPING.store(false, Ordering::Release);
    result
}

pub fn is_connected() -> bool {
    CONFIG_SERVER_CLIENT
        .lock()
        .ok()
        .and_then(|client| client.as_ref().map(|managed| managed.client.is_connected()))
        .unwrap_or(false)
}

/// # Safety
/// `out_error` must point to caller-owned storage for one C string pointer, or be null.
pub unsafe fn stop_ffi(out_error: *mut *const c_char) -> c_int {
    unsafe { ffi_result_with_error(out_error, stop) }
}

#[cfg(test)]
mod tests {
    use super::build_config_server_url;

    #[test]
    fn config_server_url_appends_token_to_base_path() {
        let url = build_config_server_url("wss://config.example.com/api/v1", "device-token")
            .expect("valid config server URL");

        assert_eq!(url, "wss://config.example.com/api/v1/device-token");
    }

    #[test]
    fn config_server_url_percent_encodes_token_as_one_path_segment() {
        let url = build_config_server_url("udp://config.example.com:22020", "token/with spaces")
            .expect("valid config server URL");

        assert_eq!(url, "udp://config.example.com:22020/token%2Fwith%20spaces");
    }

    #[test]
    fn config_server_url_rejects_secret_bearing_endpoint_components() {
        assert!(build_config_server_url("tcp://user@config.example.com", "token").is_err());
        assert!(build_config_server_url("tcp://config.example.com?debug=true", "token").is_err());
        assert!(build_config_server_url("tcp://config.example.com#fragment", "token").is_err());
    }

    #[test]
    fn config_server_url_rejects_empty_token() {
        assert!(build_config_server_url("tcp://config.example.com", "").is_err());
    }
}
