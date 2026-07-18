#pragma once
#include <stdint.h>

int32_t gateway_start(
  const char *config_json,
  const char *secrets_json,
  const char **out_error
);
int32_t gateway_apply_config(
  const char *config_json,
  const char *secrets_json_or_null,
  const char **out_error
);
int32_t gateway_stop(const char **out_error);
int32_t gateway_status(const char **out_json, const char **out_error);
int32_t gateway_request_renewal(
  const char *certificate_id_or_null,
  const char **out_error
);
void free_string(const char *s);
