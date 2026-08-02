# EasyTier macOS

EasyTier macOS publishes private-network applications through a local Gateway while keeping certificate policy, runtime deployment, and public serving behavior explicit.

## Account And Network Language

**Account Profile**:
The remote control-plane identity metadata associated with a signed-in person.
_Avoid_: Network account, device account

**Saved Account**:
An Account Profile and Device Binding retained on this Mac for later use.
_Avoid_: Logged-in account, account session

**Account Credential**:
The secret Config Server bootstrap credential retained for one Saved Account.
_Avoid_: Account Profile, login state

**Active Account**:
The only Saved Account, if any, whose Account Credential currently drives the Config Server connection.
_Avoid_: Selected account, current profile

**Device Binding**:
The association between one Account Profile and this Mac's enrollment with Config Server.
_Avoid_: Account identity, network identity

**Managed Network**:
A network assigned by Config Server to the current Device Binding.
_Avoid_: Account Network, saved network

**Local Network**:
A network configured and owned on this Mac without an Account Profile.
_Avoid_: Offline account network, unmanaged account network

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
