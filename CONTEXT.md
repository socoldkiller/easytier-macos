# EasyTier macOS

EasyTier macOS publishes private-network applications through a local Gateway while keeping certificate policy, runtime deployment, and public serving behavior explicit.

## Gateway Language

**Published Service**:
A user-declared mapping from a public domain to one private-network upstream.
_Avoid_: Route, proxy entry

**Certificate Policy**:
The immutable authority, challenge method, domains, and DNS credential selection used by one certificate attempt.
_Avoid_: ACME preference, fallback chain

**Desired Configuration**:
The latest saved Gateway intent selected by the user, whether or not a runtime has accepted it yet.
_Avoid_: Current configuration, active configuration

**Applied Configuration**:
The exact Gateway configuration that the running privileged runtime reports as accepted.
_Avoid_: Saved configuration, effective preference

**Deployment Identity**:
The configuration identifier, revision, and fingerprint that prove two Gateway configurations are identical.
_Avoid_: Generation counter, version number

**Configuration Convergence**:
The condition in which Desired Configuration and Applied Configuration have the same Deployment Identity.
_Avoid_: Synced, probably applied

**Active Certificate**:
Non-expired certificate material currently eligible to terminate TLS for a Published Service.
_Avoid_: Latest certificate, configured certificate

**Issuance Attempt**:
One ACME order executed against exactly one Certificate Policy.
_Avoid_: Certificate job, fallback attempt

**Retry Schedule**:
The earliest persisted time at which a failed Issuance Attempt may be tried again.
_Avoid_: Renewal date, cooldown

**Provider Cooldown**:
A provider-declared period, normally derived from rate limiting, during which eligible work must not be retried.
_Avoid_: Backoff, retry delay

**DNS Cleanup Obligation**:
A persisted requirement to remove a DNS-01 challenge record that could not be cleaned up during its Issuance Attempt.
_Avoid_: Orphan hint, cleanup warning
