#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct KeyValuePair {
  const char *key;
  const char *value;
} KeyValuePair;

int32_t parse_config(const char *cfg_str);
int32_t run_network_instance(const char *cfg_str);
int32_t retain_network_instance(const char **inst_names, uintptr_t length);
int32_t collect_network_infos(KeyValuePair *infos, uintptr_t max_length);
void get_error_msg(const char **out);
void free_string(const char *s);
int32_t connect_rpc_client(const char *client_id, const char *url);
int32_t disconnect_rpc_client(const char *client_id);
int32_t call_json_rpc(
  const char *client_id,
  const char *service_name,
  const char *method_name,
  const char *domain,
  const char *payload_json,
  const char **out_json
);
