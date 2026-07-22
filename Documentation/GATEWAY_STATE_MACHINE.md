# Gateway State Machine

The Gateway deliberately separates saved user intent, privileged runtime deployment, certificate issuance, and serving behavior. These are related state machines, not one loose status string.

## Canonical model

- **Desired Configuration** is the latest persisted user intent.
- **Applied Configuration** is the exact configuration reported by the running Gateway runtime.
- **Deployment Identity** is `(configuration ID, revision, fingerprint)`. Equality requires all three fields to match.
- **Certificate Policy** is the authority, challenge, domains, and DNS credential revision used by an Issuance Attempt.
- **Active Certificate** is valid material currently available to TLS.
- **Issuance Attempt** is one order against one immutable Certificate Policy.
- **Retry Schedule** is per certificate and records the earliest next eligible attempt.
- **Provider Cooldown** records a provider rate-limit window. ACME authority cooldowns apply across certificates using that authority.
- **DNS Cleanup Obligation** survives the attempt and process restarts until cleanup succeeds.
- **Configuration Convergence** exists only when Desired and Applied Deployment Identities are exactly equal.

## Configuration convergence

The Swift runtime controller owns this state machine:

```text
Disabled
   | enable with valid desired configuration
   v
Applying ------------------------------+
   | exact applied identity observed   | ambiguous XPC result or transient failure
   v                                   v
Converged                         Retry Scheduled
   | desired identity changes          | retry deadline
   +-----------------> Applying <-------+

Applying -- local validation or credential failure --> Blocked
Blocked  -- relevant configuration/credential change --> Applying

Any enabled state -- disable --> Stopping --> Disabled
```

The controller persists Desired Configuration before convergence. An apply failure never rolls it back. If XPC times out or returns an ambiguous error, the controller queries helper status; an exact matching Applied Deployment Identity proves success. A process-local counter or an acknowledgement without matching status is not proof.

Apply retry delays are `1s, 5s, 15s, 30s, 60s`, followed by a `300s` cap. Local validation and unavailable credentials are blocked conditions rather than network retries. A desired revision change resets apply backoff.

The UI must present both sides when they differ:

```text
Configured: ZeroSSL / DNS-01
Runtime:    Let's Encrypt / HTTP-01
State:      Saved configuration not yet applied
```

This is deployment divergence, never fallback.

## Certificate lifecycle

Certificate availability and certificate operation are orthogonal.

Availability:

```text
Unavailable | Valid | Expired
```

Operation:

```text
Queued
  | scheduler eligibility and no active cooldown
  v
Issuing | Renewing | Replacing
  | success, current policy, durable install
  v
Idle

Issuing/Renewing/Replacing -- transient/interrupted --> Waiting Retry
Issuing/Renewing/Replacing -- rate limited ----------> Waiting Retry + Provider Cooldown
Issuing/Renewing/Replacing -- user action/permanent --> Suspended

Waiting Retry -- retry deadline and cooldown expired --> Queued
Suspended -- manual retry or relevant policy/credential revision --> Queued
Any active attempt -- policy changes --> stale result discarded, current policy Queued
```

The active operation is selected from existing material:

- No Active Certificate: `Issuing`.
- Valid Active Certificate with the same Certificate Policy: `Renewing`.
- Valid Active Certificate with a different Certificate Policy: `Replacing`.

An attempt reports these stages:

```text
Account
Ordering
Provisioning Challenge
Validating
Finalizing
Downloading
Cleanup
Installing
```

One attempt uses exactly one authority and one challenge method. No error may switch from Let's Encrypt to ZeroSSL, from ZeroSSL to Let's Encrypt, from DNS-01 to HTTP-01, or from HTTP-01 to DNS-01.

## Failure classification

| Failure | Kind | State | Retry behavior |
| --- | --- | --- | --- |
| Network timeout, connection error, ACME 5xx | Transient | Waiting Retry | Persisted exponential backoff |
| ACME 429 or `rateLimited` | Rate Limited | Waiting Retry | Honor `Retry-After`; otherwise one-hour authority cooldown |
| ZeroSSL EAB 429 | Rate Limited | Waiting Retry | Honor `Retry-After`; otherwise one-hour ZeroSSL cooldown |
| ACME unauthorized, rejected identifier, account action required, other 4xx | User Action Required | Suspended | Configuration/credential change or manual retry |
| Missing or mismatched DNS credential | User Action Required | Suspended or apply blocked before deployment | Credential revision/change |
| Cloudflare/Aliyun 401, 403, invalid access/signature, missing zone | User Action Required | Suspended | Fix provider access or zone selection |
| Cloudflare/Aliyun 429 | Rate Limited | Waiting Retry | Per-certificate provider retry deadline; it must not freeze the ACME authority |
| DNS propagation timeout | Transient | Waiting Retry | Persisted backoff after cleanup attempt |
| Certificate download/network failure | Transient unless ACME says otherwise | Waiting Retry | Persisted backoff or authority cooldown |
| Invalid SAN, key mismatch, invalid validity, unsupported local material | Permanent | Suspended | Policy change or manual retry after remediation |
| Certificate storage/journal commit failure | Permanent | Suspended | Preserve valid Active Certificate; require storage remediation |
| Process restart during an attempt | Interrupted | Waiting Retry | Fresh order after a persisted one-minute delay |

Manual retry clears ordinary retry/suspension state, but it does not bypass an active rate-limit deadline. A manual retry for all certificates skips certificates that remain rate limited.

## Persistence and restart

The certificate coordinator journal persists:

- Certificate Policy key.
- Failure attempt count.
- Next renewal time.
- Next retry time.
- In-flight marker.
- Typed last failure.
- ACME authority cooldowns.

The DNS cleanup journal separately persists provider, credential ID, record identity, attempt count, next cleanup time, and last error.

Partial ACME orders are not resumed. On restart, an in-flight marker becomes an interrupted failure and a fresh order becomes eligible only after the persisted delay. A corrupt coordinator journal is quarantined; a journal write failure suspends new issuance rather than starting work that cannot be recovered safely.

Issued PEM data is validated in memory first. It is not persisted by the ACME task. The coordinator commits it only after confirming that the attempt's Certificate Policy still matches current configuration. Certificate files are written into a new generation, made durable, and activated by an atomic pointer update. Therefore:

- A stale successful attempt cannot overwrite current certificate state.
- A failed install cannot corrupt the previous active generation.
- A valid previous certificate can remain active while replacement is waiting or suspended.
- The certificate storage layout is intentionally destructive; legacy layouts are not migrated.

DNS-01 cleanup runs after success, failure, or cancellation. Failed cleanup becomes a DNS Cleanup Obligation with persistent exponential backoff. A stale attempt is still cleaned up before its result is discarded.

Remote ACME contact synchronization is independent background work. Its network failure is exposed as a runtime issue and retried, but it cannot abort local configuration apply or change the selected Certificate Policy.

## Serving derivation

Serving behavior is derived only from Active Certificate validity:

```text
Valid Active Certificate
  HTTPS: terminate TLS and proxy configured business traffic
  HTTP:  redirect ordinary requests to HTTPS

No valid Active Certificate
  HTTP-01 path: serve only the exact active challenge response
  Other HTTP:    503 Service Unavailable
  HTTPS:         no certificate is selected
```

DNS-01 never enables plaintext business proxying. An expired certificate is removed from active TLS material and is equivalent to no valid certificate for serving decisions.

## Invariants

1. No CA fallback.
2. No challenge fallback.
3. No plaintext business-traffic fallback.
4. Swift validation must preserve authority and challenge exactly.
5. Desired Configuration persists independently from Applied Configuration.
6. Apply success requires exact Deployment Identity equality.
7. A valid old certificate may serve while replacement is pending or suspended.
8. Expired or absent material never enables plaintext proxying.
9. Stale attempt output is cleaned up and discarded before persistence or installation.
10. ACME authority cooldowns survive restart and apply across that authority.
11. Manual retry never bypasses an active provider deadline.
12. Remote contact synchronization cannot block local apply.
