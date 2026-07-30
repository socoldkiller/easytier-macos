#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct KeyValuePair {
  const char *key;
  const char *value;
} KeyValuePair;

typedef void (*ConfigServerEventCallback)(const char *event_json, void *context);

int32_t parse_config(const char *cfg_str, const char **out_error);
int32_t run_network_instance(const char *cfg_str, const char **out_error);
int32_t retain_network_instance(const char **inst_names, uintptr_t length, const char **out_error);
int32_t stop_network_instance(const char **inst_names, uintptr_t length, const char **out_error);
int32_t collect_network_infos(KeyValuePair *infos, uintptr_t max_length, const char **out_error);
void free_string(const char *s);
int32_t connect_rpc_client(const char *client_id, const char *url, const char **out_error);
int32_t call_json_rpc(
  const char *client_id,
  const char *service_name,
  const char *method_name,
  const char *domain,
  const char *payload_json,
  const char **out_json,
  const char **out_error
);
int32_t configure_rpc_portal(
  int32_t enabled,
  const char *listen_addr,
  const char **whitelist,
  uintptr_t whitelist_count,
  const char **out_error
);
int32_t start_config_server_client(
  const char *endpoint,
  const char *token,
  const char *device_name,
  const char *machine_id,
  int32_t secure_required,
  ConfigServerEventCallback callback,
  void *context,
  const char **out_error
);
int32_t stop_config_server_client(const char **out_error);
int32_t is_config_server_client_active(void);
int32_t is_config_server_client_connected(void);
