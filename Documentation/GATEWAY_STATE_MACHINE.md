# Gateway State Machine

The Gateway deliberately separates saved user intent, privileged runtime deployment, certificate issuance, and serving behavior. These are related state machines, not one loose status string.

## Canonical model

- **Desired Configuration** is the latest persisted user intent.
- **Applied Configuration** is the exact configuration reported by the running Gateway runtime.
- **Deployment Identity** is `(configuration ID, revision, fingerprint)`. Equality requires all three fields to match.
- **Managed Certificate** is persisted user intent with a stable identity, one domain pattern, and either an Automatic wildcard or Custom exact-host strategy.
- **Attempt Policy** is the immutable authority, challenge, domain, and DNS credential revision used by one Issuance Attempt.
- **Preferred Authority** is the persisted CA selected for the next Automatic attempt. It starts at Let's Encrypt and becomes ZeroSSL only after an eligible Let's Encrypt failure.
- **Active Certificate** is valid material currently available to TLS.
- **Fallback Certificate** is previous valid material retained while a service transitions to a different managed certificate.
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

The UI must present both sides when they differ. For example:

```text
Configured: Automatic / DNS-01
Runtime:    ZeroSSL / DNS-01
State:      Saved configuration not yet applied
```

This is deployment divergence. CA fallback occurs only inside the Automatic certificate strategy after configuration has converged.

## Certificate strategies

Automatic is the default service choice. Services on the same node reuse one managed wildcard certificate for `*.node.magicDNSSuffix`. A newly created Automatic certificate captures the currently selected default DNS credential; later changes to the global default affect only newly created Automatic certificates.

Automatic always uses DNS-01 and begins with Let's Encrypt. It may move to ZeroSSL only after a classified CA-side failure. A successful CA becomes the persisted preferred authority for later renewals and survives process restart.

Custom is deliberately literal: one exact host, one selected authority, and one selected DNS-01 or HTTP-01 challenge. Custom never changes authority, never changes challenge, and never enables HTTP-only serving.

Managed certificates are independent from routes. An Automatic wildcard may be shared by multiple routes. When no enabled route references it, its material and history remain stored but `renewal_enabled` is false, so the runtime does not issue or renew it. A dormant certificate becomes eligible again when an enabled route references it.

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

One attempt uses exactly one authority and one challenge method. An attempt never mutates in place. Automatic may schedule a new ZeroSSL attempt after an eligible Let's Encrypt failure, but it never changes DNS-01 to HTTP-01. Custom never schedules a different authority or challenge.

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
| Certificate download/network failure | Transient unless ACME says otherwise | Waiting Retry | Persisted backoff or authority cooldown |
| Invalid SAN, key mismatch, invalid validity, unsupported local material | Permanent | Suspended | Policy change or manual retry after remediation |
| Certificate storage/journal commit failure | Permanent | Suspended | Preserve valid Active Certificate; require storage remediation |
| Process restart during an attempt | Interrupted | Waiting Retry | Fresh order after a persisted one-minute delay |

Automatic authority switching is intentionally narrower than retry classification:

- Account, order, authorization, finalize, or certificate-download failures may switch from Let's Encrypt to ZeroSSL only when classified as Rate Limited, User Action Required, or Permanent.
- Transient and Interrupted failures retry the same authority.
- DNS provider, DNS propagation, configuration, certificate validation, storage, and runtime failures never switch authority.
- ZeroSSL is the final Automatic authority. An eligible ZeroSSL failure may exhaust Automatic, but it does not switch back to Let's Encrypt implicitly.
- Authority cooldowns apply to the authority that will actually be attempted. A Let's Encrypt cooldown does not block the newly selected ZeroSSL fallback.

Manual retry clears ordinary retry/suspension state, but it does not bypass an active rate-limit deadline. A manual retry for all certificates skips certificates that remain rate limited.

## Persistence and restart

The certificate coordinator journal persists:

- Certificate Policy key.
- Preferred Automatic authority.
- Whether the certificate has ever activated HTTPS.
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
- Automatic fallback selection and the never-downgrade history survive restart even when no current certificate material is loadable.
- The certificate storage layout is intentionally destructive; legacy layouts are not migrated.

DNS-01 cleanup runs after success, failure, or cancellation. Failed cleanup becomes a DNS Cleanup Obligation with persistent exponential backoff. A stale attempt is still cleaned up before its result is discarded.

Remote ACME contact synchronization is independent background work. Its network failure is exposed as a runtime issue and retried, but it cannot abort local configuration apply or change the selected Certificate Policy.

## Serving derivation

Each route names a primary managed certificate and may temporarily name a fallback certificate during a strategy transition. TLS selects the first valid installed material in primary-then-fallback order.

```text
Valid primary or fallback certificate
  HTTPS: terminate TLS and proxy configured business traffic
  HTTP:  redirect ordinary requests to HTTPS

No valid primary or fallback certificate
  HTTP-01 path: serve only the exact active challenge response
  Other HTTP:    plaintext proxy only when initial Automatic is exhausted;
                 otherwise 503 Service Unavailable
  HTTPS:         no certificate is selected
```

HTTP-only is a narrow terminal mode for initial Automatic setup. It is enabled only when all of the following are true:

- The managed certificate uses Automatic.
- The preferred/current authority is ZeroSSL.
- ZeroSSL ended with an eligible CA-side exhaustion failure after the Let's Encrypt fallback decision.
- Neither primary nor fallback certificate material is valid.
- The managed certificate has never activated HTTPS.

DNS, configuration, validation, storage, runtime, Transient, and Interrupted failures never enable HTTP-only. Any certificate that has ever served HTTPS never silently downgrades, even after restart or after its material later becomes unavailable. If issuance later succeeds while a route is in HTTP-only mode, the route automatically returns to HTTPS and ordinary HTTP redirects.

Expired material is removed from active TLS selection. Valid old material may continue serving as the route fallback while a replacement certificate is pending, waiting, or suspended. Once the new primary is valid, Swift clears the transition fallback reference.

## Invariants

1. Automatic starts with Let's Encrypt and may fall back only once to ZeroSSL for classified CA-side failures.
2. Transient failures retry the same authority; non-CA failures never switch authority.
3. No challenge fallback exists.
4. Custom preserves its exact authority and challenge and never enables HTTP-only.
5. Desired Configuration persists independently from Applied Configuration.
6. Apply success requires exact Deployment Identity equality.
7. A valid old primary may serve as fallback material while replacement is pending or suspended.
8. HTTP-only requires initial Automatic exhaustion, no valid primary/fallback material, and no prior HTTPS activation.
9. Stale attempt output is cleaned up and discarded before persistence or installation.
10. ACME authority cooldowns survive restart and apply across that authority.
11. Manual retry never bypasses an active provider deadline.
12. Remote contact synchronization cannot block local apply.
13. Automatic preferred authority and HTTPS activation history survive restart.
14. Dormant Automatic certificates retain material but do not issue or renew.
