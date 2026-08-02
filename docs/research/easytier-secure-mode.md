# EasyTier Secure Mode: problem analysis

Date: 2026-08-02

## Executive conclusion

Secure Mode is not merely another encryption toggle. It replaces EasyTier's legacy
"one shared network password implies equal trust" model with three separate
security mechanisms:

1. Per-session authenticated encryption between nodes, including end-to-end
   encryption when traffic is relayed.
2. Optional public-key pinning for authenticating a shared node or public relay.
3. Expiring, revocable credentials for admitting temporary nodes without giving
   them the main `network_secret`.

The primary problem it solves is excessive trust concentration in
`network_secret`: in legacy mode, every node that receives the secret becomes a
fully trusted network member, and leakage requires rotating the password for the
whole network. Secure Mode reduces the blast radius and separates transport
encryption, server identity, and network authorization.

## What changes compared with legacy mode

### 1. End-to-end sessions instead of one network-wide traffic secret

In legacy mode, nodes in a network derive encryption from the common
`network_secret`. Anyone who obtains that secret can authenticate as a regular
node and may compromise traffic protected by that common trust root.

With Secure Mode, direct peer connections use a Noise XX handshake with X25519,
ChaChaPoly, and SHA-256. Relayed peer-to-peer sessions use Noise IK with the same
primitive family. Thus, a public relay forwards encrypted packets but does not
receive the endpoint session key.

This addresses:

- A third-party relay reading application traffic.
- Captured traffic being decrypted merely because the network password later
  becomes known.
- Replay of old handshake or session material.
- One static traffic key protecting the whole network indefinitely.

Sources:

- [Official Secure Mode guide](https://easytier.cn/en/guide/network/secure-mode.html)
- `Vendor/EasyTier/easytier/src/peers/peer_conn.rs` (`Noise_XX_25519_ChaChaPoly_SHA256`)
- `Vendor/EasyTier/easytier/src/peers/relay_peer_map.rs` (`Noise_IK_25519_ChaChaPoly_SHA256`)

### 2. Shared-node identity can be authenticated

Encryption alone does not prove which server is on the other end. A client that
enables Secure Mode but does not pin the shared node's key has an encrypted but
unauthenticated connection to that shared node.

The shared node can persist a stable `local_private_key`; clients then associate
the expected `peer_public_key` with that peer. This is a trust-on-configuration
model comparable to certificate/public-key pinning: a substituted server cannot
complete authentication with the pinned identity.

This addresses:

- DNS, routing, or endpoint substitution that sends the client to an impostor.
- A man-in-the-middle presenting itself as the intended public relay.

It requires the public key to be distributed through a separate trusted channel.
If the shared node does not persist its private key, its identity changes after a
restart and existing pins stop working.

Sources:

- [Official Secure Mode guide, shared-node scenario](https://easytier.cn/en/guide/network/secure-mode.html#scenario-2-connecting-through-a-shared-node-public-relay)
- `Vendor/EasyTier/easytier/src/common/config.rs` (`PeerConfig.peer_public_key`, `process_secure_mode_cfg`)
- `Vendor/EasyTier/easytier/src/proto/common.proto` (`SecureModeConfig`)

### 3. Temporary access no longer requires sharing the main password

An admin node that still holds `network_secret` can issue a separate credential.
The temporary node joins with the credential private material and does not need
the main network password.

A credential supports:

- Mandatory expiry (`ttl_seconds`).
- Manual revocation by credential ID.
- Optional ACL group membership.
- Relay permission, disabled by default.
- Allowed subnet-proxy CIDRs, empty by default.
- Reusability control in the upstream RPC/CLI.

Revocation and credential trust information propagate through the network; the
official guide states that an already-connected node using a revoked credential
is removed. One credential per device gives useful audit and revocation
granularity.

This addresses:

- Contractors, guests, CI runners, and temporary devices learning the permanent
  network password.
- Rotating the entire network secret when one temporary device is lost.
- Temporary access that otherwise has no automatic expiry.
- Temporary nodes silently becoming relay or subnet-gateway infrastructure.

ACL groups are labels, not an access policy by themselves. Actual resource access
still requires corresponding ACL rules.

Sources:

- [Official Secure Mode guide, credential scenario](https://easytier.cn/en/guide/network/secure-mode.html#scenario-3-issuing-network-credentials-for-temporary-devices)
- `Vendor/EasyTier/easytier/src/proto/api_instance.proto` (`CredentialManageRpc`)
- `Vendor/EasyTier/easytier/src/peers/credential_manager.rs`
- `Vendor/EasyTier/easytier/src/peers/peer_ospf_route.rs`

## What it does not solve

- It does not protect plaintext on a compromised endpoint.
- It does not prevent traffic analysis; a relay may still observe connection
  metadata, timing, and packet sizes.
- It does not solve denial-of-service or availability attacks.
- Secure Mode without `peer_public_key` does not authenticate a public relay.
- A leaked `network_secret` still lets an attacker attempt to join as a fully
  trusted/admin-class node. Secure Mode improves session isolation and historical
  confidentiality, but the secret must still be rotated after compromise.
- A leaked credential remains usable until expiry or revocation and must be
  handled as sensitive private-key material.
- Credential groups do not restrict traffic unless ACL rules consume them.

## Upgrade and compatibility constraints

- Upgrade shared/server nodes before clients. A Secure Mode server can accept a
  legacy client, but a Secure Mode client cannot connect to a legacy server.
- Credential trust propagation requires all participating admin, temporary, and
  transit nodes to support Secure Mode.
- The web client/web console should be upgraded as well because its tunnel also
  participates in the secure protocol.

Source: [Official Secure Mode guide, upgrade notes](https://easytier.cn/en/guide/network/secure-mode.html#upgrade-notes).

## Current state of this macOS repository

The bundled EasyTier submodule is `v2.6.4` at commit
`8428a89d2dabc94c97d370ec607c6ca142473626`. Secure Mode was introduced upstream
before `v2.6.0`, so the bundled Rust core already contains the protocol and
credential-management RPC.

The native macOS configuration layer does not yet expose the complete feature:

- `NetworkConfig` contains `network_secret` and `credential_file`, but no
  `secure_mode` configuration or join credential.
- `NetworkConfigTOMLCodec` does not encode/decode `[secure_mode]`.
- Peers are represented as `[String]`, so `[[peer]].peer_public_key` cannot be
  preserved or edited.
- The UI's current `Disable encryption` flag controls the legacy
  `flags.enable_encryption` setting; it is not Secure Mode.
- The app already stores `network_secret` in Keychain, which is the right pattern
  to extend to stable node private keys and credential secrets.

Relevant project files:

- `Sources/EasyTierShared/Models/NetworkModels.swift`
- `Sources/EasyTierShared/NetworkConfigTOMLCodec.swift`
- `Sources/EasyTierMac/Features/Configuration/ConfigEditorView.swift`
- `Sources/EasyTierShared/NetworkSecretStore.swift`

## Recommended product decomposition

Treat this as a security feature family rather than one checkbox:

1. **Secure transport for regular nodes**: add `[secure_mode].enabled` while
   retaining `network_secret`. This is the smallest usable increment.
2. **Authenticated shared nodes**: add stable local identity-key storage and a
   structured peer model with `peer_public_key` pinning. The UI must clearly warn
   that an unpinned public relay is encrypted but unauthenticated.
3. **Temporary-node join**: support credential input as a mutually exclusive
   alternative to `network_secret`, stored in Keychain.
4. **Credential administration**: generate, list, revoke, show expiry, configure
   ACL groups/relay/proxy permissions, and persist the admin credential database
   through a helper-owned path.

Calling only step 1 "full Secure Mode support" would be misleading because it
omits the two features that solve shared-node impersonation and password sharing.
