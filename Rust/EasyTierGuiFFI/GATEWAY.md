# TLS Gateway v1

The gateway is a statically linked Pingora reverse proxy exposed through the C ABI in
`EasyTierFFI.h`. It terminates TLS with BoringSSL, selects certificates by SNI, and routes exact
domains to HTTP or HTTPS upstreams.

## Rust library selection

- `pingora` 0.8.1 with `proxy` and `boringssl` provides the HTTP/1.1 and HTTP/2 reverse-proxy
  engine, connection pooling, upstream TLS, and downstream BoringSSL integration.
- `instant-acme` 0.8.5 provides ACME account persistence, orders, HTTP-01/DNS-01 challenges,
  certificate finalization, ARI renewal information, and replacement-order support.
- `cloudflare` 0.14.0 with its Rustls transport provides typed zone discovery and DNS record APIs.
- DNS-01 providers create and clean up challenge TXT records through their provider APIs; the ACME
  authority performs the protocol-defined DNS validation.

These crates are compiled into the Rust `staticlib`; BoringSSL is not a runtime dylib dependency.

## Runtime model

- `gateway_start` binds both listeners and returns before ACME issuance finishes.
- HTTP-01 challenge responses take priority over redirects and proxy routes.
- Plain HTTP returns `503` while a certificate is pending, then redirects to HTTPS with `308`.
- HTTPS requires an exact route, a matching SNI/Host pair, and an active certificate.
- Upstream hostnames are resolved through the process/system resolver. If Magic DNS is active as
  the system resolver, its names can be used directly in upstream URLs. Resolution occurs during
  start and apply, so an address change requires reapplying the current gateway configuration.
- Route and certificate snapshots can be replaced with `gateway_apply_config`. Listener,
  `storage_dir`, and ACME directory changes require stop/start.
- Certificates renew from ACME ARI when available, with a lifetime-based fallback schedule.
  Failed orders retry with bounded backoff, and successful certificates hot-swap without listener
  restart.

## Configuration

Configuration and secrets are separate UTF-8 JSON documents. Both currently use schema version 5.

```json
{
  "schema_version": 5,
  "storage_dir": "/Users/example/Library/Application Support/EasyTier/Gateway",
  "listeners": {
    "http": "127.0.0.1:5002",
    "https": "127.0.0.1:5443",
    "dns": "127.0.0.1:53535"
  },
  "local_dns": {
    "domains": ["admin.example.com", "grafana.apps.example.com"],
    "answer_ipv4": "127.0.0.1",
    "ttl": 30
  },
  "acme": {
    "contact_email": "ops@example.com",
    "terms_of_service_agreed": true
  },
  "certificates": [
    {
      "id": "admin-http01",
      "domains": [
        "admin.example.com"
      ],
      "authority": "letsencrypt",
      "challenge": {
        "type": "http01"
      }
    },
    {
      "id": "apps-dns01",
      "domains": [
        "*.apps.example.com"
      ],
      "authority": "zerossl",
      "challenge": {
        "type": "dns01",
        "provider": "cloudflare",
        "credential_id": "cloudflare-main"
      }
    }
  ],
  "routes": [
    {
      "domain": "admin.example.com",
      "certificate_id": "admin-http01",
      "upstream": {
        "url": "http://admin-node.magic:8080",
        "host_header": null,
        "tls_server_name": null
      }
    },
    {
      "domain": "grafana.apps.example.com",
      "certificate_id": "apps-dns01",
      "upstream": {
        "url": "https://grafana-node.magic:3000",
        "host_header": "grafana.internal",
        "tls_server_name": "grafana.internal"
      }
    }
  ]
}
```

Each certificate selects exactly one authority:

```json
"letsencrypt"
"zerossl"
```

There is no authority or challenge fallback. A failed request retries only the configured authority
and the configured HTTP-01 or DNS-01 challenge.

Secrets use credential references rather than embedding tokens in the main configuration:

```json
{
  "schema_version": 5,
  "cloudflare": {
    "cloudflare-main": {
      "api_token": "runtime-token"
    }
  }
}
```

Cloudflare tokens should be scoped to `Zone:Read` and `DNS:Edit` for only the zones used by the
gateway. Tokens are retained in memory using zeroizing storage and are not written to the gateway
storage directory or status JSON.

## ACME reachability

For HTTP-01, the public domain must resolve to the gateway and public TCP port 80 must reach the
configured HTTP listener. The macOS Swift integration binds port 80 in its privileged helper;
standalone high-port deployments still require an external port forward.

For normal HTTPS traffic, public TCP port 443 must similarly reach the configured HTTPS listener.
The macOS helper binds port 443 directly. DNS-01 does not require inbound port 80 and is required
for wildcard certificates.

## C ABI

```c
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

int32_t gateway_status(
  const char **out_json,
  const char **out_error
);

int32_t gateway_request_renewal(
  const char *certificate_id_or_null,
  const char **out_error
);
```

Return value `0` means success and `-1` means failure. Strings returned through `out_json` or
`out_error` are owned by the caller and must be released with `free_string`.

- Starting twice fails.
- Applying or requesting renewal while stopped fails.
- Null apply secrets retain the current in-memory secrets.
- Null or empty renewal ID queues all configured certificates.
- Stop is idempotent.
- Status while stopped returns a versioned stopped snapshot.

## macOS Swift and privileged-helper integration

The macOS app wraps the C ABI through a dedicated `GatewayClient`. The GUI-owned configuration
contains only ACME, certificate, and route fields; the privileged helper injects the security-
sensitive runtime fields before calling Rust:

- HTTP listens on `0.0.0.0:80` and HTTPS listens on `0.0.0.0:443`.
- Runtime storage is `/Library/Application Support/EasyTier/Gateway/<uid>/runtime`.
- Every published service explicitly selects Let's Encrypt or ZeroSSL and HTTP-01 or DNS-01.
- DNS-01 credentials support Cloudflare and Aliyun and remain stored in Keychain.

The user's desired state is stored at
`~/Library/Application Support/com.kkrainbow.easytier.mac/gateway/config.json`. The helper validates
the app's code signature, binds Gateway ownership to the initiating GUI UID, serializes all Gateway
FFI calls, and stops the listeners when the owning GUI exits or its XPC lease expires. Gateway
runtime data is preserved across normal quit and software updates so ACME accounts and certificates
can be reused.

The automated tests run the ACME protocol, Cloudflare API shape, exact authority/challenge selection, certificate
issuance, ARI replacement, cleanup persistence, TLS termination, and proxying against controlled
local servers. Real Let's Encrypt or ZeroSSL issuance still requires a user-controlled public domain,
DNS credentials or public port routing, so it remains a deployment smoke test rather than a repository test.
