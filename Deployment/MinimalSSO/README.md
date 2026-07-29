# EasyTier Native SSO Sidecar

This sidecar lets the macOS app use Casdoor login without changing `easytier-web` source code.
It owns only `/.well-known/easytier-client` and `/native/*`; all existing frontend, API,
OIDC callback, session, dashboard, and Config Server behavior remains upstream.

## Browser flow

1. The Mac opens `/native/login` with a loopback port and random state.
2. The sidecar performs a confidential OIDC authorization-code flow with nonce and PKCE.
3. After verifying the ID Token, it extracts the configured username claim.
4. The browser makes a second, normally silent, visit to easytier-web's existing OIDC login.
   Casdoor already has a browser session, so the user is not asked for the password again.
5. The coordinator page waits for both the sidecar result and
   `/api/v1/auth/check_login_status`, then returns a 60-second HMAC ticket to the Mac.
6. The Mac exchanges the ticket for the username and connects to the upstream Config Server
   as `tcp://host:port/<username>`.

Tickets contain no Casdoor token, easytier-web Cookie, or Config Server URL. The ticket key
must decode to at least 32 random bytes and must not be committed.

## Casdoor

Keep the existing easytier-web confidential application. Add this second redirect URI to it:

```text
https://iw.example.com/native/oidc/callback
```

The existing URI remains unchanged:

```text
https://iw.example.com/api/v1/auth/oidc/callback
```

The sidecar may share that application's client ID and secret because both callbacks belong to
the same HTTPS origin. A separate Casdoor application is also supported if stronger operational
isolation is preferred.

Use `JWT-Standard` token format and ensure the ID Token includes the configured username claim.

## Deployment

1. Copy `.env.example` to the deployment's secret environment file and fill every value.
2. Add `docker-compose.sidecar.yml` to the existing Compose project or copy its service block.
3. Route the two narrow URL spaces with `easytier-client.caddy` before the catch-all
   easytier-web reverse proxy.
4. Build and start the sidecar, then verify:

```sh
curl --fail --silent --show-error https://iw.example.com/.well-known/easytier-client
curl --fail --silent --show-error https://iw.example.com/native/health
```

The sidecar is intentionally stateless. In-progress browser sign-ins are lost on restart and can
simply be retried. Stable account metadata and the username credential remain owned by the Mac
app and privileged helper.
