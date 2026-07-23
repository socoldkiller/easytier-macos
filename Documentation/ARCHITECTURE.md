# EasyTier macOS Architecture

## Dependency direction

```text
EasyTierApp (composition root and application shell)
        |
        v
AppContext (the only application Environment entry)
        |
        +-- WorkspaceFeature ------> EasyTierAppStore
        |                              |-- EasyTierCoreClient
        |                              |-- NetworkSecretStore
        |                              `-- SystemSleepPreventing
        |
        +-- SettingsFeature --------> AppAppearanceSettings
        |                              |   `-- DockIconVisibilityApplying
        |                              `-- LoginItemController
        |                                  `-- LoginItemService
        |
        +-- SoftwareUpdateFeature --> SoftwareUpdateRuntimeManaging
        |                              |-- PrivilegedHelperLifecycle
        |                              `-- SoftwareUpdateClient
        |
        `-- AppPresentation --------> MenuBarStatusItemController
                                      |-- GlassRenderCoordinator
                                      `-- WindowPresentationModel

Platform adapters implement the consumer-owned protocols:

SystemDockIconVisibilityService -> DockIconVisibilityApplying
SystemLoginItemService          -> LoginItemService
SystemPrivilegedHelperLifecycle -> PrivilegedHelperLifecycle
SparkleSoftwareUpdateClient     -> SoftwareUpdateClient
```

EasyTier Core and Gateway have separate privileged process owners. `EasyTierMac`
talks to `EasyTierPrivilegedHelper` through `com.kkrainbow.easytier.mac.helper`
for network/RPC operations, and to `GatewayPrivilegedHelper` through
`com.coldkiller.gateway.helper` for Gateway, ACME, certificate, and proxy
operations. Both TUN and `no_tun` configurations use only the EasyTier helper.
The two helpers have independent registration, XPC protocols, lifecycles, and
build metadata. They also have independent native linkage chains:

```text
EasyTierPrivilegedHelper -> EasyTierCoreRuntime -> CEasyTierCoreFFI -> libeasytier_core_ffi.a
GatewayPrivilegedHelper  -> GatewayRuntime      -> CGatewayFFI      -> libgateway_ffi.a
```

The two Rust archives are compiled from mutually exclusive Cargo features. The
EasyTier helper does not contain Gateway entry points, the Gateway helper does
not contain EasyTier Core entry points, and the GUI contains neither set.

## Gateway ownership

Gateway is split across three deep modules with narrow interfaces:

```text
GatewayRuntimeController (Swift)
  owns Desired Configuration and convergence retries
                |
                | XPC apply/status using exact Deployment Identity
                v
GatewayPrivilegedHelper
  owns the local apply transaction, helper lifecycle, and resolver rollback
                |
                | schema-checked runtime configuration and secrets
                v
Rust certificate coordinator
  owns Automatic CA fallback, issuance, renewal, replacement, cooldowns,
  cleanup, serving material, HTTP-only eligibility, and the persistent journal
```

The Swift controller owns managed-certificate intent: shared Automatic wildcard
certificates, exact-host Custom certificates, DNS credential selection, and
primary/fallback references during strategy transitions. It never infers runtime success from a request acknowledgement.
It compares Desired and Applied Deployment Identities. The helper never performs
remote ACME contact synchronization as a prerequisite for local apply. The Rust
coordinator keeps every attempt immutable. For Automatic only, it persists the
preferred authority and may schedule ZeroSSL after a classified Let's Encrypt
CA-side failure. It never changes the selected challenge method, and Custom never
changes authority.

Internal seams isolate behavior that varies:

- ACME authority and HTTP transport adapters implement Let's Encrypt, ZeroSSL,
  EAB acquisition, `Retry-After`, and account contact operations.
- DNS provider adapters implement Cloudflare and Aliyun presentation/cleanup.
- Storage adapters own account credentials, atomic certificate generations,
  coordinator journals, and DNS cleanup obligations.
- Scheduling functions isolate renewal windows, exponential retry delays, and
  jitter calculations so their policy can be tested without listener behavior.
- Serving derivation selects valid primary then fallback material, and permits
  HTTP-only only for an Automatic certificate that exhausted both authorities
  before ever activating HTTPS.

See `Documentation/GATEWAY_STATE_MACHINE.md` for the canonical state model,
failure classification, restart behavior, and serving invariants.

`AppContext` is concrete intentionally. SwiftUI can observe concrete `@Observable`
models reached through it without existential type erasure. Replaceable capabilities
sit behind consumer-owned protocols instead of turning `AppContext` into a dynamic
service locator.

## State ownership

- `EasyTierApp` owns exactly one shared state root: `@State private var appContext`.
- Views read shared state only through `@Environment(AppContext.self)`.
- A feature owns its long-lived observable model; child views receive values,
  bindings, and actions or resolve that feature through `AppContext`.
- Ephemeral presentation state remains local `@State` in the view that owns it.
- Persistent or platform state is injected at the composition root. Views do not
  reach directly for `UserDefaults.standard`, `SMAppService`, or app-owned singletons.
- AppKit delegate lifecycle state stays on the delegate instance owned by
  `@NSApplicationDelegateAdaptor`. Shell actions such as Quit are injected as
  closures; they must not use static mutable delegate state.
- Cross-feature orchestration belongs in `AppContext` or in a dedicated protocol
  adapter. Feature views must not initialize sibling feature services.
- SwiftUI container backgrounds, presentation backgrounds, and AppKit hosting
  controllers may create independent hosting graphs. Pass the minimum dependency
  explicitly, or inject `AppContext` at that hosting root; do not assume a parent
  window's Environment crosses the hosting boundary.

## Source ownership

```text
Sources/EasyTierMac/
  Application/             App entry point and dependency composition
    Presentation/          App-owned presentation state and service aggregation
    Shell/
      MainWindow/          Main window navigation and feature composition
      MenuBar/             Status item and popover composition
    PreviewSupport/        In-memory, disabled, and no-op preview adapters
  Features/
    Configuration/         Network editor, TOML, and Keychain-facing UI
    LinuxInstall/          Linux installation guide
    Logs/                  Runtime log presentation and export
    Peers/                 Peer subscriptions and peer cards
    Settings/              Settings navigation and consumer-owned preferences
      Appearance/          Appearance state and Dock visibility contract
      LoginItem/           Login item state and service contract
    SoftwareUpdate/        Framework-neutral update state and coordination
    Status/                Runtime/member status presentation
    Traffic/               Traffic charts and sampling presentation
    Workspace/             Core workspace state boundary
  Platform/
    Services/
      Appearance/          NSApplication Dock visibility adapter
      LoginItem/           ServiceManagement login item adapter
      PrivilegedHelper/    Privileged helper lifecycle adapter
      SoftwareUpdate/      Sparkle client and delegate bridge
    Windowing/             AppKit window and visual-effect bridges
  SharedUI/                Feature-neutral visual components
```

These folders are ownership modules inside the `EasyTierMac` target. This keeps file
discovery automatic for SwiftPM and Xcode synchronized groups, so agents can add or
move files inside a feature without editing `Package.swift` or the project file.
Promote a feature to a separate SwiftPM target only when its public contract is stable
and it no longer depends on sibling UI implementation details.

## Dependency injection rules

1. Define a protocol in the consuming feature, close to the use site.
2. Keep protocol requirements narrow and behavior-oriented.
3. Put macOS, Sparkle, ServiceManagement, and XPC implementations under `Platform`.
4. Construct live implementations only in `AppContext.live()`.
5. Pass test doubles through initializers; do not add `static shared` escape hatches.
6. Keep FFI, XPC, Keychain, and persistence APIs out of SwiftUI view bodies.

Current examples include `DockIconVisibilityApplying`, `LoginItemService`,
`PrivilegedHelperLifecycle`, `SoftwareUpdateRuntimeManaging`,
`SoftwareUpdateClient`, `SoftwareUpdateClientDelegate`, `EasyTierCoreClient`,
`PeerSubscriptionDataLoading`, `NetworkSecretStore`, and `SystemSleepPreventing`.

## Multi-agent workflow

- Assign one agent to one feature directory whenever possible.
- Treat `Application/AppContext.swift`, `Application/AppContextComposition.swift`,
  `Application/EasyTierApp.swift`, `Package.swift`, and shared domain models as
  high-contention files; assign one integration owner to these files.
- Land a protocol contract before parallel implementations when multiple features
  need the same capability.
- Put feature-specific tests in a correspondingly named test file. Shared behavior
  belongs in `EasyTierSharedTests`; app composition belongs in `EasyTierMacTests`.
- Avoid drive-by formatting or broad renames outside the assigned feature.
- Keep cross-feature changes as a small contract patch plus independent feature
  patches so Git can merge them with minimal overlap.

## Adding a feature

1. Create `Sources/EasyTierMac/Features/<FeatureName>/`.
2. Add a small feature root that owns the observable model or service facade.
3. Declare external capabilities as protocols in that directory.
4. Add the feature root to `AppContext` and wire its live adapters in
   `AppContext.live()`.
5. Access it from SwiftUI through `@Environment(AppContext.self)`; do not add another
   root environment object.
6. Add unit tests for the feature model and protocol wiring before UI tests.

Application entry surfaces that compose several features belong under
`Application/Shell`, not under `Features`. A system or framework adapter belongs
under `Platform`, while the protocol it implements stays with the consuming feature.
