import Foundation
import Observation
import TOML

public struct TOMLExportOptions: Equatable, Sendable {
    public var includeNetworkSecret: Bool

    public init(includeNetworkSecret: Bool = false) {
        self.includeNetworkSecret = includeNetworkSecret
    }
}

@MainActor
@Observable
public final class EasyTierAppStore {
    public var configs: [NetworkConfig] = [] {
        didSet {
            refreshSelectedRuntimeSnapshotsIfNeeded()
            notifyRuntimeEnvironmentDidChange()
        }
    }
    public var selectedConfigID: String? {
        didSet {
            if oldValue != nil, oldValue != selectedConfigID {
                invalidateSecretAuthenticationSession()
            }
            refreshSelectedRuntimeSnapshotsIfNeeded()
            notifyRuntimeEnvironmentDidChange()
        }
    }
    public var mode: AppMode = .default
    public var instances: [NetworkInstance] = [] {
        didSet {
            instancesWriteCount += 1
            reconcileSelectedConfigWithRuntimeManagedConfigs()
            refreshSelectedRuntimeSnapshotsIfNeeded()
            notifyRuntimeEnvironmentDidChange()
        }
    }
    public var runtimeDetails: [String: NetworkInstanceRunningInfo] = [:] {
        didSet {
            runtimeDetailsWriteCount += 1
            refreshSelectedRuntimeSnapshotsIfNeeded()
            notifyRuntimeEnvironmentDidChange()
        }
    }
    public var selectedTab: WorkspaceTab = .status
    public var logLines: [LogEntry] = []
    public var isBusy = false
    public var isQuitting = false
    public var lastError: String?
    public private(set) var persistenceHealth: PersistenceHealth = .preparing
    public var persistenceIsReady: Bool { persistenceHealth == .ready }
    public var isShowingSettings = false
    public var isShowingAbout = false
    public var isShowingLinuxInstallGuide = false
    @ObservationIgnored public var trafficSamplesByInstance: [String: [TrafficSample]] = [:] {
        didSet {
            trafficSamplesByInstanceWriteCount += 1
            refreshSelectedRuntimeSnapshotsIfNeeded()
        }
    }
    @ObservationIgnored private var statusMetricsByInstance: [String: [String: RuntimeMemberStatusMetricsSnapshot]] = [:]
    @ObservationIgnored private var trafficSamplingStatusByInstance: [String: RuntimeTrafficSamplingStatus] = [:]
    @ObservationIgnored private var runtimeMemberPresentation = RuntimeMemberPresentationState()
    public private(set) var selectedStatusSnapshot: RuntimeStatusSnapshot = .empty
    public private(set) var selectedTrafficSnapshot: RuntimeTrafficSnapshot = .empty
    public private(set) var networkSecretSessionRevision: UInt64 = 0
    @ObservationIgnored private var networkSecretAccessGeneration: UInt64 = 0
    @ObservationIgnored private var cachedNetworkSecret: CachedNetworkSecret?
    public var runtimeIntents: [RuntimeIntent] = []
    public var reversedPortForwardFingerprints: [String: Set<String>] = [:]
    public var vpnOnDemandEnabled = false
    public var magicDNSSettings: MagicDNSSettings = .default {
        didSet { notifyRuntimeEnvironmentDidChange() }
    }
    public var remoteConfigSession: RemoteConfigSession?
    public var peerSubscriptions: [PeerSubscription] = []
    public var isRefreshingPeerSubscriptions = false
    public var pendingPeerCardMerge: PeerCard?
    public private(set) var runtimeTransitionsByConfigID: [String: NetworkRuntimeTransition] = [:]

    /// Presentation-only scroll state. Runtime collection must continue while
    /// this is true so topology changes are not hidden behind a stale gesture.
    public var isAnyViewScrolling = false

    public static func portForwardFingerprint(for rule: PortForwardConfig) -> String {
        "\(rule.bind_ip):\(rule.bind_port)-\(rule.dst_ip):\(rule.dst_port)-\(rule.proto)"
    }

    private let runtimeClient: any EasyTierCoreClient
    public let helperRegistration: HelperRegistrationService?
    private let database: ApplicationDatabase
    private let networkSecretStore: any NetworkSecretStore
    private let peerSubscriptionDataLoader: any PeerSubscriptionDataLoading
    private let systemSleepPreventer: any SystemSleepPreventing
    private var lastErrorKind: LastErrorKind?

    @ObservationIgnored private lazy var runtimeSession = RuntimeSessionController(
        runtimeClient: runtimeClient,
        helperRegistration: helperRegistration,
        systemSleepPreventer: systemSleepPreventer
    )
    @ObservationIgnored private var isPublishingRuntimePresentation = false
    @ObservationIgnored private var runtimeOperationGeneration: UInt64 = 0
    @ObservationIgnored private var runtimeRefreshRevision: UInt64 = 0
    @ObservationIgnored private var lastAppliedRuntimeRefreshRevision: UInt64 = 0
    @ObservationIgnored private var runtimeMutationLocked = false
    @ObservationIgnored private var runtimeMutationInProgress = false
    @ObservationIgnored private var runtimePresentationActivity: RuntimePresentationActivity = .interactive
    @ObservationIgnored private var runtimeMutationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var busyOperationCount = 0
    @ObservationIgnored private var runtimeServiceConfigured = false
    @ObservationIgnored private var persistedSelectedConfigID: String?
    @ObservationIgnored package var runtimeEnvironmentDidChange: (@MainActor @Sendable () -> Void)?

    @ObservationIgnored public private(set) var runtimeDetailsWriteCount = 0
    @ObservationIgnored public private(set) var instancesWriteCount = 0
    @ObservationIgnored public private(set) var trafficSamplesByInstanceWriteCount = 0

    private struct CachedNetworkSecret {
        var namespace: String
        var value: String
    }

    private struct RuntimeStartResult {
        var error: Error?
        var secretOutcome: NetworkSecretOperationOutcome
    }

    private struct ConfigRestartOperationResult {
        var result: ConfigApplyResult
        var secretOutcome: NetworkSecretOperationOutcome
    }

    private struct ResolvedNetworkSecretConfig {
        var config: NetworkConfig
        var outcome: NetworkSecretOperationOutcome
    }

    private enum LastErrorKind { case helperPermission }

    public func resetWriteCounters() {
        runtimeDetailsWriteCount = 0
        instancesWriteCount = 0
        trafficSamplesByInstanceWriteCount = 0
    }

    package init(
        runtimeClient: any EasyTierCoreClient = PrivilegedEasyTierClient(),
        helperRegistration: HelperRegistrationService? = nil,
        storage: EasyTierStorage = .default,
        database: ApplicationDatabase? = nil,
        networkSecretStore: any NetworkSecretStore = SystemNetworkSecretStore(),
        peerSubscriptionDataLoader: any PeerSubscriptionDataLoading = URLSessionPeerSubscriptionDataLoader(
            session: URLSession(configuration: .ephemeral)
        ),
        systemSleepPreventer: any SystemSleepPreventing = IOKitSystemSleepPreventer()
    ) {
        self.runtimeClient = runtimeClient
        self.helperRegistration = helperRegistration
        self.database = database ?? ApplicationDatabase(
            baseDirectory: storage.baseDirectory,
            gatewayFileURL: storage.baseDirectory.appending(path: "gateway/config.json"),
            networkSecretStore: networkSecretStore
        )
        self.networkSecretStore = networkSecretStore
        self.peerSubscriptionDataLoader = peerSubscriptionDataLoader
        self.systemSleepPreventer = systemSleepPreventer
    }

    /// Convenience initializer for tests that use one runtime client.
    package convenience init(
        client: any EasyTierCoreClient = PrivilegedEasyTierClient(),
        storage: EasyTierStorage = .isolatedForTesting(),
        networkSecretStore: any NetworkSecretStore = SystemNetworkSecretStore(),
        peerSubscriptionDataLoader: any PeerSubscriptionDataLoading = URLSessionPeerSubscriptionDataLoader(
            session: URLSession(configuration: .ephemeral)
        ),
        systemSleepPreventer: any SystemSleepPreventing = IOKitSystemSleepPreventer()
    ) {
        self.init(
            runtimeClient: client,
            helperRegistration: nil,
            storage: storage,
            networkSecretStore: networkSecretStore,
            peerSubscriptionDataLoader: peerSubscriptionDataLoader,
            systemSleepPreventer: systemSleepPreventer
        )
    }

    private func withRuntimeMutation(
        ifGeneration expectedGeneration: UInt64? = nil,
        _ operation: () async -> Void
    ) async {
        if runtimeMutationLocked {
            await withCheckedContinuation { continuation in
                runtimeMutationWaiters.append(continuation)
            }
        } else {
            runtimeMutationLocked = true
            runtimeMutationInProgress = true
        }

        defer {
            if runtimeMutationWaiters.isEmpty {
                runtimeMutationInProgress = false
                runtimeMutationLocked = false
            } else {
                runtimeMutationWaiters.removeFirst().resume()
            }
        }
        if let expectedGeneration, runtimeOperationGeneration != expectedGeneration { return }
        runtimeOperationGeneration &+= 1
        busyOperationCount += 1
        isBusy = true
        defer {
            busyOperationCount -= 1
            isBusy = busyOperationCount > 0
        }
        await operation()
        do {
            try await refreshRuntimeThrowing(allowDuringRuntimeMutation: true)
            if let runtimeError = selectedStatusSnapshot.runtimeError {
                setLastError(runtimeError)
            }
        } catch {
            setLastError(error)
            log("Runtime refresh failed after operation: \(error.localizedDescription)")
        }
        if !runtimeTransitionsByConfigID.isEmpty {
            runtimeTransitionsByConfigID.removeAll()
            notifyRuntimeEnvironmentDidChange()
        }
    }

    private func setRuntimeTransition(
        _ transition: NetworkRuntimeTransition,
        for configID: String
    ) {
        runtimeTransitionsByConfigID[configID] = transition
        notifyRuntimeEnvironmentDidChange()
    }

    private func notifyRuntimeEnvironmentDidChange() {
        runtimeEnvironmentDidChange?()
    }

    public var selectedConfig: NetworkConfig? {
        get {
            guard let selectedConfigID else { return nil }
            return presentedConfigs.first { $0.id == selectedConfigID }
        }
        set {
            guard let newValue else { return }
            if let index = configs.firstIndex(where: { $0.id == newValue.instance_id }) {
                configs[index] = newValue
            }
        }
    }

    /// Runtime-managed configs are presentation-only projections of networks
    /// started by Config Server. They never enter workspace persistence.
    public var runtimeManagedConfigs: [NetworkConfig] {
        instances.compactMap { instance in
            guard localConfig(matching: instance) == nil else { return nil }
            let detail = runtimeDetails[instance.name] ?? instance.detail
            return NetworkConfig(
                instance_id: instance.instance_id,
                hostname: detail?.my_node_info?.hostname,
                network_name: instance.name,
                network_secret: nil,
                credential_file: nil,
                listener_urls: [],
                dev_name: detail?.dev_name ?? "",
                no_tun: false
            )
        }
    }

    public var presentedConfigs: [NetworkConfig] {
        configs + runtimeManagedConfigs
    }

    public var selectedConfigIsRuntimeManaged: Bool {
        guard let selectedConfigID else { return false }
        return runtimeManagedConfigs.contains { $0.id == selectedConfigID }
    }

    public var selectedRunningInstance: NetworkInstance? {
        guard let config = selectedConfig else { return nil }
        return runningInstance(matching: config)
    }

    public var isMagicDNSResolverActive: Bool {
        !runningMagicDNSConfigNames().isEmpty
    }

    /// A tracked instance includes a start request that has been accepted but
    /// has not produced a ready runtime snapshot yet.
    public var selectedConfigCanStop: Bool {
        selectedRunningInstance != nil
    }

    /// Compatibility alias for control flow; this does not mean the network is ready.
    public var selectedConfigIsRunning: Bool {
        selectedConfigCanStop
    }

    public var selectedRuntimeReadinessPhase: RuntimeReadinessPhase {
        selectedStatusSnapshot.runtimeReadinessPhase
    }

    public var selectedConfigIsReady: Bool {
        selectedRuntimeReadinessPhase == .ready
    }

    public func runningInstance(matching config: NetworkConfig) -> NetworkInstance? {
        let instanceID = config.instance_id
        let networkName = config.network_name

        if let byID = instances.first(where: { instance in instance.instance_id == instanceID }) { return byID }
        return uniquelyMatchedInstance(named: networkName)
    }

    public func config(matching instance: NetworkInstance) -> NetworkConfig? {
        if let local = localConfig(matching: instance) { return local }
        let instanceID = instance.instance_id
        let networkName = instance.name

        if let byID = runtimeManagedConfigs.first(where: { $0.instance_id == instanceID }) { return byID }
        let matches = runtimeManagedConfigs.filter { $0.network_name == networkName }
        return matches.count == 1 ? matches[0] : nil
    }

    public func runtimeReadinessPhase(matching config: NetworkConfig) -> RuntimeReadinessPhase {
        guard let instance = runningInstance(matching: config) else { return .stopped }
        return instance.runtimeReadinessPhase(
            requiresTUN: config.requiresTUN,
            runtimeDetail: runtimeDetails[instance.name] ?? instance.detail
        )
    }

    public func instanceIsFullyConnected(_ instance: NetworkInstance) -> Bool {
        guard let config = config(matching: instance) else { return false }
        let detail = runtimeDetails[instance.name] ?? instance.detail
        guard instance.runtimeReadinessPhase(requiresTUN: config.requiresTUN, runtimeDetail: detail) == .ready else {
            return false
        }
        var resolved = instance
        resolved.detail = detail
        return resolved.isFullyConnected(expectRemotePeers: config.expectsRemotePeerConnection)
    }

    public var selectedRuntimeDetail: NetworkInstanceRunningInfo? {
        selectedStatusSnapshot.runtimeDetail
    }

    public var selectedMemberStatuses: [NetworkMemberStatus] {
        selectedStatusSnapshot.members
    }

    public var selectedLiveMemberStatuses: [NetworkMemberStatus] {
        selectedStatusSnapshot.members.filter(\.isLive)
    }

    private func refreshSelectedRuntimeSnapshotsIfNeeded() {
        guard !isPublishingRuntimePresentation else { return }
        refreshSelectedRuntimeSnapshots()
    }

    private func refreshSelectedRuntimeSnapshots() {
        let config = selectedConfig
        let instance = config.flatMap { runningInstance(matching: $0) }
        let detail = instance.flatMap { runtimeDetails[$0.name] ?? $0.detail }
        let statusMetrics = instance.flatMap { statusMetricsByInstance[$0.name] }
        let presentedMembers = instance.flatMap {
            runtimeMemberPresentation.visibleMembersByInstanceName[$0.name]
        }
        let trafficSamples = instance.flatMap { trafficSamplesByInstance[$0.name] } ?? []
        let trafficSamplingStatus = instance.flatMap { trafficSamplingStatusByInstance[$0.name] }

        let statusSnapshot = RuntimeStatusSnapshot.build(
            selectedConfig: config,
            runningInstance: instance,
            runtimeDetail: detail,
            memberStatusMetricsByID: statusMetrics,
            presentedMembers: presentedMembers
        )
        if selectedStatusSnapshot != statusSnapshot {
            selectedStatusSnapshot = statusSnapshot
        }

        let trafficSnapshot = RuntimeTrafficSnapshot.build(
            selectedConfig: config,
            runningInstance: instance,
            samples: trafficSamples,
            samplingStatus: trafficSamplingStatus
        )
        if selectedTrafficSnapshot != trafficSnapshot {
            selectedTrafficSnapshot = trafficSnapshot
        }
    }

    public func load() async {
        persistenceHealth = .preparing
        do {
            let state = try await database.loadWorkspace()
            configs = state.configs
            runtimeIntents = state.runtimeIntents
            reversedPortForwardFingerprints = state.reversedPortForwardFingerprints
            vpnOnDemandEnabled = state.vpnOnDemandEnabled
            magicDNSSettings = state.magicDNSSettings
            mode = state.mode
            peerSubscriptions = state.peerSubscriptions
            if let selectedConfigID = state.selectedConfigID,
               configs.contains(where: { $0.id == selectedConfigID })
            {
                self.selectedConfigID = selectedConfigID
            } else {
                selectedConfigID = configs.first?.id
            }
            persistenceHealth = .ready
            log("Loaded \(configs.count) saved network config(s).")
        } catch {
            if configs.isEmpty {
                configs = [NetworkConfig()]
                selectedConfigID = configs.first?.id
            }
            persistenceHealth = .unavailable(PersistenceFailure(
                message: error.localizedDescription,
                databaseURL: database.databaseURL
            ))
            setLastError(error)
            log("Failed to load state: \(error.localizedDescription)")
        }
        await refreshRuntime()
        startPolling()
    }

    @discardableResult
    public func retryPersistence() async -> Bool {
        do {
            try await database.retryPreparation()
            await load()
            return persistenceHealth == .ready
        } catch {
            persistenceHealth = .unavailable(PersistenceFailure(
                message: error.localizedDescription,
                databaseURL: database.databaseURL
            ))
            setLastError(error)
            return false
        }
    }

    @discardableResult
    public func rebuildPersistence() async -> Bool {
        do {
            try await database.rebuildEmptyDatabase()
            await load()
            return persistenceHealth == .ready
        } catch {
            persistenceHealth = .unavailable(PersistenceFailure(
                message: error.localizedDescription,
                databaseURL: database.databaseURL
            ))
            setLastError(error)
            return false
        }
    }

    @discardableResult
    public func prepareRuntimeServiceAfterLaunch() async -> Bool {
        await prepareRuntimeService(surfaceError: true)
    }

    @discardableResult
    public func resumeRuntimeServiceIfApproved() async -> Bool {
        guard let helperRegistration else { return true }
        await helperRegistration.refresh()
        guard helperRegistration.state == .enabled else {
            runtimeServiceConfigured = false
            return false
        }
        return await prepareRuntimeService(surfaceError: true)
    }

    private func prepareRuntimeService(surfaceError: Bool) async -> Bool {
        do {
            try await ensureRuntimeServiceReady()
            await refreshRuntime()
            return true
        } catch {
            if surfaceError {
                setLastError(error)
                log("Runtime helper preparation failed: \(Self.errorMessage(for: error))")
            }
            return false
        }
    }

    private func ensureRuntimeServiceReady() async throws {
        guard let helperRegistration else { return }
        try await helperRegistration.ensureRegistered()
        guard !runtimeServiceConfigured else { return }
        try await runtimeClient.configureRPCPortal(mode.rpcPortal, whitelist: mode.rpcPortalWhitelist)
        runtimeServiceConfigured = true
    }

    public func save() async {
        do {
            try await commitPersistenceState(stateForStorage())
        } catch {
            setLastError(error)
            log("Save failed: \(error.localizedDescription)")
        }
    }

    public func addConfig() async {
        // The first network takes the fixed-port listener defaults
        // (tcp/udp 11010, wg/ws 11011, ...). Any later network reuses the
        // same schemes with port 0 so the OS picks non-conflicting ports
        // instead of clashing with the first network's bound listeners.
        let listeners = configs.isEmpty
            ? NetworkConfig().listener_urls
            : ListenerURLDefaults.autoPortListeners
        let config = NetworkConfig(
            network_name: uniqueNetworkName(),
            listener_urls: listeners
        )
        do {
            var state = try stateForStorage()
            state.configs.append(config)
            state.selectedConfigID = config.id
            try await commitPersistenceState(state)
            selectedTab = .config
            log("Added \(config.network_name).")
        } catch {
            setLastError(error)
            log("Could not add \(config.network_name): \(error.localizedDescription)")
        }
    }

    public func deleteSelectedConfig() async {
        await withRuntimeMutation {
            guard let selectedConfigID, let index = configs.firstIndex(where: { $0.id == selectedConfigID }) else { return }
            let config = configs[index]
            let runningInstanceName = runningInstance(matching: config)?.name
            var instanceNames = [config.network_name]
            if let runningInstanceName, runningInstanceName != config.network_name {
                instanceNames.insert(runningInstanceName, at: 0)
            }
            setRuntimeTransition(.stopping, for: config.instance_id)
            do {
                try await runtimeClient.stop(instanceNames: instanceNames)
                for instanceName in instanceNames {
                    runtimeSession.clearTrafficTracking(instanceName: instanceName)
                }
            } catch {
                setLastError(error)
                log("Delete canceled because \(config.network_name) could not be stopped: \(error.localizedDescription)")
                return
            }
            do {
                try await networkSecretStore.deleteSecret(for: config, purpose: .delete)
                clearCachedNetworkSecret(for: config)
            } catch {
                if Self.isNetworkSecretAccessCancellation(error) {
                    log("Network deletion canceled during Keychain authorization.")
                } else {
                    setLastError(error)
                    log("Delete canceled because the saved network secret could not be removed: \(error.localizedDescription)")
                }
                return
            }
            var state: WorkspacePersistenceState
            do {
                state = try stateForStorage()
            } catch {
                setLastError(error)
                return
            }
            state.runtimeIntents.removeAll { intent in
                intent.target.isLocal && (intent.target.instanceID == config.instance_id || intent.target.networkName == config.network_name)
            }
            state.reversedPortForwardFingerprints.removeValue(forKey: config.instance_id)
            state.configs.remove(at: index)
            let nextIndex = min(index, state.configs.count - 1)
            state.selectedConfigID = state.configs.isEmpty ? nil : state.configs[nextIndex].id
            do {
                try await commitPersistenceState(state)
                runtimeSession.clearConfigTracking(for: config)
                runtimeSession.clearPendingStart(for: config)
                log("Deleted \(config.network_name).")
            } catch {
                setLastError(error)
                log("Delete failed after Keychain cleanup: \(error.localizedDescription)")
            }
        }
    }

    public func updateConfig(
        id: String,
        with config: NetworkConfig,
        saveImmediately: Bool = false
    ) async throws {
        guard let index = configs.firstIndex(where: { $0.id == id }) else { return }
        let sanitized = Self.configWithoutNetworkSecret(config)
        if saveImmediately {
            var state = try stateForStorage()
            state.configs[index] = sanitized
            try await commitPersistenceState(state)
        } else {
            configs[index] = sanitized
        }
    }

    public func selectConfig(id: String?) async {
        guard selectedConfigID != id else { return }
        guard id == nil || presentedConfigs.contains(where: { $0.id == id }) else { return }
        if let id, runtimeManagedConfigs.contains(where: { $0.id == id }) {
            selectedConfigID = id
            return
        }
        do {
            var state = try stateForStorage()
            state.selectedConfigID = id
            try await commitPersistenceState(state)
        } catch {
            setLastError(error)
            log("Could not save network selection: \(error.localizedDescription)")
        }
    }

    public func selectPreviousConfig() async {
        await selectConfig(offset: -1)
    }

    public func selectNextConfig() async {
        await selectConfig(offset: 1)
    }

    @discardableResult
    public func runSelectedConfig(
        networkSecretInput: NetworkSecretInput? = nil
    ) async -> NetworkSecretOperationOutcome {
        guard !selectedConfigIsRuntimeManaged else { return .none }
        var outcome = NetworkSecretOperationOutcome.none
        await withRuntimeMutation {
            outcome = await runSelectedConfigWithoutMutationLock(
                networkSecretInput: networkSecretInput
            ).secretOutcome
        }
        return outcome
    }

    private func runSelectedConfigWithoutMutationLock(
        networkSecretInput: NetworkSecretInput? = nil
    ) async -> RuntimeStartResult {
        guard let config = selectedConfig else {
            return RuntimeStartResult(error: nil, secretOutcome: .none)
        }
        return await runConfigWithoutMutationLock(
            config,
            networkSecretInput: networkSecretInput
        )
    }

    private func runConfigWithoutMutationLock(
        _ config: NetworkConfig,
        networkSecretInput: NetworkSecretInput? = nil
    ) async -> RuntimeStartResult {
        guard !isQuitting else {
            return RuntimeStartResult(error: nil, secretOutcome: .none)
        }
        guard runningInstance(matching: config) == nil else {
            log("Start skipped because \(config.network_name) is already tracked.")
            return RuntimeStartResult(error: nil, secretOutcome: .none)
        }
        setRuntimeTransition(.starting, for: config.instance_id)
        var secretOutcome = NetworkSecretOperationOutcome.none
        let error = await busy {
            log("Starting \(config.network_name)...")
            try validateConfigForCurrentRuntime(config)
            let resolution = try await configWithResolvedNetworkSecret(
                config,
                input: networkSecretInput,
                purpose: .run,
                reason: "Use the network secret to start \(config.network_name)."
            )
            secretOutcome = resolution.outcome
            let keychainConfig = resolution.config
            let cleanConfig = Self.configWithoutReversedPortForwards(keychainConfig, fingerprints: reversedPortForwardFingerprints)
            do {
                try await ensureRuntimeServiceReady()
            } catch {
                runtimeSession.setPendingStartAfterApproval(Self.configWithoutNetworkSecret(cleanConfig))
                throw error
            }
            guard !isQuitting else { return }
            try await runtimeClient.run(toml: try encodedTOML(for: cleanConfig))
            runtimeSession.recordPendingStart(for: config)
            log("Start requested for \(config.network_name).")
        }
        return RuntimeStartResult(error: error, secretOutcome: secretOutcome)
    }

    /// Retry the most recent start after the user approved the privileged helper.
    public func retryStartAfterHelperApproval() async {
        guard !isQuitting else { return }
        guard let config = runtimeSession.takePendingStartAfterApproval() else { return }
        if let helperRegistration {
            await helperRegistration.refresh()
            guard !isQuitting else { return }
            guard helperRegistration.state == .enabled else {
                runtimeSession.restorePendingStartAfterApprovalIfEmpty(config)
                setLastError("Privileged helper is still not enabled. Approve EasyTier in System Settings > Login Items & Extensions, then try again.", kind: .helperPermission)
                return
            }
        }
        await withRuntimeMutation {
            guard !isQuitting,
                  configs.contains(where: { $0.instance_id == config.instance_id })
            else { return }
            setRuntimeTransition(.starting, for: config.instance_id)
            await busy {
                do {
                    try await ensureRuntimeServiceReady()
                } catch {
                    runtimeSession.restorePendingStartAfterApprovalIfEmpty(config)
                    throw error
                }
                let keychainConfig = try await configWithKeychainSecret(
                    config,
                    purpose: .run,
                    reason: "Use the network secret to start \(config.network_name) after helper approval."
                )
                try await runtimeClient.run(toml: try encodedTOML(for: keychainConfig))
                runtimeSession.recordPendingStart(for: config)
                log("Start requested for \(config.network_name) after helper approval.")
            }
        }
    }

    public func stopSelectedConfig() async {
        guard !selectedConfigIsRuntimeManaged else { return }
        await withRuntimeMutation {
            await stopSelectedConfigWithoutMutationLock()
        }
    }

    private func stopSelectedConfigWithoutMutationLock() async {
        guard let config = selectedConfig else { return }
        setRuntimeTransition(.stopping, for: config.instance_id)
        await busy {
            log("Stopping \(config.network_name)...")
            guard let runningInstance = runningInstance(matching: config) else {
                log("Stop skipped because \(config.network_name) is not running.")
                return
            }
            try await persistRuntimeHostname(from: runningInstance, forConfigID: config.instance_id)
            try await runtimeClient.stop(instanceNames: [runningInstance.name])
            runtimeSession.clearTrafficTracking(instanceName: runningInstance.name)
            runtimeSession.clearPendingStart(for: config)
            runtimeSession.clearConfigTracking(for: config)
            log("Stopped \(config.network_name).")
        }
    }

    @discardableResult
    public func restartSelectedConfig(
        replacing instance: NetworkInstance,
        configID targetConfigID: String? = nil,
        networkSecretInput: NetworkSecretInput? = nil
    ) async -> NetworkSecretOperationOutcome {
        guard !selectedConfigIsRuntimeManaged else { return .none }
        return await restartConfig(
            replacing: instance,
            configID: targetConfigID,
            networkSecretInput: networkSecretInput
        ).secretOutcome
    }

    public func applyConfigDraft(
        configID: String,
        draft: NetworkConfig,
        replacing instance: NetworkInstance?
    ) async -> ConfigApplyResult {
        guard configs.contains(where: { $0.id == configID }) else {
            return .failed("The network configuration no longer exists.")
        }

        var persistedDraft = draft
        persistedDraft.network_secret = nil
        do {
            try await updateConfig(id: configID, with: persistedDraft, saveImmediately: true)
        } catch {
            return .failed(Self.errorMessage(for: error))
        }
        guard let instance else { return .saved }
        return await restartConfig(
            replacing: instance,
            configID: configID,
            surfaceError: false
        ).result
    }

    private func restartConfig(
        replacing instance: NetworkInstance,
        configID targetConfigID: String? = nil,
        networkSecretInput: NetworkSecretInput? = nil,
        surfaceError: Bool = true
    ) async -> ConfigRestartOperationResult {
        guard let targetConfigID = targetConfigID ?? selectedConfigID else {
            return ConfigRestartOperationResult(
                result: .failed("No network configuration is selected."),
                secretOutcome: .none
            )
        }
        var result: ConfigApplyResult = .failed("The network configuration is unavailable.")
        var secretOutcome = NetworkSecretOperationOutcome.none
        await withRuntimeMutation {
            guard !isQuitting else {
                result = .failed("EasyTier is quitting.")
                return
            }
            guard let config = configs.first(where: { $0.id == targetConfigID }) else { return }
            setRuntimeTransition(.restarting, for: config.instance_id)
            let error = await busy(surfaceError: surfaceError) {
                log("Restarting \(config.network_name)...")
                try validateConfigForCurrentRuntime(config, replacing: instance)
                let resolution = try await configWithResolvedNetworkSecret(
                    config,
                    input: networkSecretInput,
                    purpose: .restart,
                    reason: "Use the network secret to restart \(config.network_name)."
                )
                secretOutcome = resolution.outcome
                let keychainConfig = resolution.config
                let cleanConfig = Self.configWithoutReversedPortForwards(keychainConfig, fingerprints: reversedPortForwardFingerprints)
                do {
                    try await ensureRuntimeServiceReady()
                } catch {
                    runtimeSession.setPendingStartAfterApproval(Self.configWithoutNetworkSecret(cleanConfig))
                    throw error
                }
                try await runtimeClient.validate(toml: try encodedTOML(for: cleanConfig))
                guard !isQuitting else { return }
                try await runtimeClient.stop(instanceNames: [instance.name])
                runtimeSession.clearTrafficTracking(instanceName: instance.name)
                runtimeSession.clearPendingStart(for: config)
                guard !isQuitting else { return }
                try await runtimeClient.run(toml: try encodedTOML(for: cleanConfig))
                runtimeSession.recordPendingStart(for: config)
                log("Restart requested for \(config.network_name).")
            }
            result = error.map { .failed(Self.errorMessage(for: $0)) } ?? .restarted
        }
        return ConfigRestartOperationResult(result: result, secretOutcome: secretOutcome)
    }

    public static func configWithoutReversedPortForwards(_ config: NetworkConfig, fingerprints: [String: Set<String>]) -> NetworkConfig {
        let reversed = fingerprints[config.instance_id] ?? []
        guard !reversed.isEmpty else { return config }
        var clean = config
        clean.port_forwards = config.port_forwards.filter { rule in
            !reversed.contains(portForwardFingerprint(for: rule))
        }
        return clean
    }

    nonisolated private static func configWithoutNetworkSecret(_ config: NetworkConfig) -> NetworkConfig {
        var config = config
        config.network_secret = nil
        return config
    }

    public func toggleSelectedConfigConnection() async {
        guard !selectedConfigIsRuntimeManaged else { return }
        await withRuntimeMutation {
            if selectedConfigCanStop {
                await stopSelectedConfigWithoutMutationLock()
            } else {
                _ = await runSelectedConfigWithoutMutationLock()
            }
        }
    }

    private func validateConfigForCurrentRuntime(_ config: NetworkConfig, replacing instance: NetworkInstance? = nil) throws {
        try NetworkConfigValidator.validate(config, activeConfigs: activeConfigsForValidation(excluding: instance))
    }

    private func activeConfigsForValidation(excluding excludedInstance: NetworkInstance?) -> [NetworkConfig] {
        instances.compactMap { instance in
            if let excludedInstance, isSameRuntimeInstance(instance, excludedInstance) { return nil }
            return config(matching: instance)
        }
    }

    private func isSameRuntimeInstance(_ lhs: NetworkInstance, _ rhs: NetworkInstance) -> Bool {
        lhs.instance_id == rhs.instance_id && lhs.name == rhs.name
    }

    public func stopAll() async {
        await withRuntimeMutation {
            for config in configs where runningInstance(matching: config) != nil {
                setRuntimeTransition(.stopping, for: config.instance_id)
            }
            await busy {
                if helperRegistration == nil || helperRegistration?.state == .enabled {
                    do {
                        try await runtimeClient.retain(instanceNames: [])
                    } catch {
                        log("Failed to stop helper-managed instances during stopAll: \(error.localizedDescription)")
                    }
                }
                runtimeSession.clearRuntimeTracking()
                log("Stopped all EasyTier instances.")
            }
        }
    }

    public func prepareForAppQuit() async {
        guard !isQuitting else { return }
        isQuitting = true
        invalidateSecretAuthenticationSession()

        if vpnOnDemandEnabled {
            await withRuntimeMutation {}
            log("Quit requested with VPN On Demand enabled; leaving EasyTier network running.")
            stopPolling()
            return
        }

        await stopAll()
        stopPolling()
        runtimeServiceConfigured = false
        if let shutdownClient = runtimeClient as? EasyTierHelperShutdownClient {
            do {
                try await shutdownClient.shutdownHelper()
                log("Privileged helper shutdown requested.")
            } catch {
                log("Privileged helper shutdown skipped: \(error.localizedDescription)")
            }
        }
    }

    public func runningConfigIDsForSoftwareUpdate() -> [String] {
        configs.compactMap { config in
            runningInstance(matching: config) == nil ? nil : config.id
        }
    }

    public func prepareForSoftwareUpdate() async {
        guard !isQuitting else { return }
        isQuitting = true
        invalidateSecretAuthenticationSession()
        await stopAll()
        stopPolling()
        runtimeServiceConfigured = false

        if let shutdownClient = runtimeClient as? EasyTierHelperShutdownClient {
            do {
                try await shutdownClient.shutdownHelper()
                log("Privileged helper shutdown requested for software update.")
            } catch {
                log("Privileged helper shutdown before software update was skipped: \(error.localizedDescription)")
            }
        }
    }

    public func restoreConfigsAfterSoftwareUpdate(configIDs: [String]) async {
        isQuitting = false
        startPolling()

        let requestedIDs = Set(configIDs)
        let configsToRestore = configs.filter { requestedIDs.contains($0.id) }
        guard !configsToRestore.isEmpty else { return }

        await withRuntimeMutation {
            for config in configsToRestore {
                if await runConfigWithoutMutationLock(config).error != nil {
                    log("Could not restore \(config.network_name) after software update.")
                }
            }
        }
    }

    public func clearLogs() {
        logLines.removeAll()
    }

    public func refreshRuntime() async {
        do {
            try await refreshRuntimeThrowing()
        } catch {
            // Do not silently swallow helper-permission errors here. Surface them
            // via `lastError` so the UI can prompt the user to approve or retry.
            setLastError(error)
        }
    }

    public func recordNotice(_ message: String) {
        log(message)
    }

    public var lastErrorIsHelperPermission: Bool {
        guard let message = lastError else { return false }
        if lastErrorKind == .helperPermission { return true }
        return message.contains("needs background permission")
            || message.contains("System Settings")
            || message.contains("macOS has not allowed")
    }

    @discardableResult
    public func upsertHostnameRuntimeIntent(
        target: RuntimeIntentTarget,
        desiredHostname: String,
        baseHostname: String?
    ) async throws -> RuntimeIntent {
        let desiredHostname = desiredHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let intent = RuntimeIntent(
            target: target,
            desiredHostname: desiredHostname,
            baseHostname: baseHostname?.trimmedNilIfEmpty,
            status: .pending
        )

        var state = try stateForStorage()
        let resolved = RuntimeIntentReconciler.upsert(intent, in: &state.runtimeIntents)
        try await commitPersistenceState(state)
        return resolved
    }

    public func markRuntimeIntent(_ id: String, status: RuntimeIntentStatus) async {
        do {
            var state = try stateForStorage()
            guard RuntimeIntentReconciler.update(id: id, in: &state.runtimeIntents, mutate: { intent in
                intent.status = status
                intent.updatedAt = Date()
            }) else { return }
            try await commitPersistenceState(state)
        } catch {
            setLastError(error)
            log("Could not save runtime intent: \(error.localizedDescription)")
        }
    }

    public func useRemoteValue(forRuntimeIntent id: String) async {
        do {
            var state = try stateForStorage()
            state.runtimeIntents.removeAll { $0.id == id }
            try await commitPersistenceState(state)
        } catch {
            setLastError(error)
            log("Could not discard runtime intent: \(error.localizedDescription)")
        }
    }

    public func keepRuntimeIntentPending(_ id: String) async {
        await markRuntimeIntent(id, status: .pending)
    }

    public func reapplyRuntimeIntent(_ id: String) async {
        guard let intent = runtimeIntents.first(where: { $0.id == id }),
              let observation = runtimeObservation(for: intent.target)
        else {
            await markRuntimeIntent(id, status: .unreachable)
            return
        }

        do {
            var state = try stateForStorage()
            guard RuntimeIntentReconciler.update(id: id, in: &state.runtimeIntents, mutate: { intent in
                intent.baseHostname = observation.hostname
                intent.status = .pending
                intent.updatedAt = Date()
            }) else { return }
            try await commitPersistenceState(state)
        } catch {
            setLastError(error)
            return
        }
        await reconcileHostnameIntent(id: id, force: true)
    }

    public func applyLocalHostnameRuntimeIntent(
        configID: String,
        runningInstance: NetworkInstance,
        desiredHostname: String,
        baseHostname: String?
    ) async {
        let target = RuntimeIntentTarget(
            networkName: runningInstance.name,
            instanceID: runningInstance.instance_id,
            recentHostname: runningInstance.detail?.my_node_info?.hostname,
            recentIPv4: runningInstance.detail?.my_node_info?.displayIPv4,
            isLocal: true
        )
        let intent: RuntimeIntent
        do {
            intent = try await upsertHostnameRuntimeIntent(
                target: target,
                desiredHostname: desiredHostname,
                baseHostname: baseHostname
            )
        } catch {
            setLastError(error)
            recordNotice("Could not save hostname for \(runningInstance.name): \(error.localizedDescription)")
            return
        }

        guard let observation = runtimeObservation(for: target) else {
            await markRuntimeIntent(intent.id, status: .unreachable)
            recordNotice("Saved hostname for \(runningInstance.name). Runtime RPC is unavailable; it will be retried while this GUI is open.")
            return
        }

        do {
            try await applyHostname(desiredHostname, to: observation)
            await markRuntimeIntent(intent.id, status: .pending)
            recordNotice("Runtime hostname patch sent for \(runningInstance.name).")
        } catch {
            await markRuntimeIntent(intent.id, status: .unreachable)
            recordNotice("Saved hostname for \(runningInstance.name), but runtime patch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Remote config editing session

    public func startRemoteConfigSession(member: NetworkMemberStatus) async {
        let prepared = RemoteConfigSessionCoordinator.preparedSession(for: member)
        remoteConfigSession = prepared
        guard prepared.isLoading else { return }

        let loaded = await RemoteConfigSessionCoordinator.load(
            prepared,
            client: EasyTierRemoteRPCClient(rpcURL: prepared.rpcURL, client: runtimeClient)
        )
        guard remoteConfigSession?.requestID == prepared.requestID else { return }
        remoteConfigSession = loaded
    }

    public func clearRemoteConfigSession() {
        remoteConfigSession = nil
    }

    @discardableResult
    public func applyRemoteConfigChanges(forceRestart: Bool = false) async -> Bool {
        guard let session = remoteConfigSession, !session.isLoading, session.loadError == nil else {
            return false
        }
        guard !session.applyState.isApplying else { return false }
        guard forceRestart || session.hasUnsavedChanges else { return true }

        var applying = session
        applying.applyState = .applying
        remoteConfigSession = applying
        let rpcClient = EasyTierRemoteRPCClient(rpcURL: applying.rpcURL, client: runtimeClient)

        do {
            try await RemoteConfigSessionCoordinator.validate(applying, client: rpcClient)
        } catch {
            failRemoteConfigApply(requestID: session.requestID, message: error.localizedDescription)
            return false
        }

        var restartError: Error?
        do {
            try await RemoteConfigSessionCoordinator.restart(applying, client: rpcClient)
        } catch {
            // A successful restart can close the RPC connection before its
            // response arrives, so confirm the new runtime before failing.
            restartError = error
        }

        if let confirmed = await verifyRemoteConfigRestart(applying) {
            guard var current = remoteConfigSession, current.requestID == session.requestID else {
                return false
            }
            current.originalConfig = confirmed.config
            current.config = confirmed.config
            current.originalConfigPayload = confirmed.rawConfig
            current.applyState = .applied
            remoteConfigSession = current
            recordNotice("Applied configuration changes and restarted \(session.member.hostname).")
            clearRemoteAppliedStateAfterDelay(requestID: session.requestID)
            return true
        }

        let message = restartError?.localizedDescription
            ?? "\(session.member.hostname) did not return with the updated configuration."
        failRemoteConfigApply(requestID: session.requestID, message: message)
        return false
    }

    private func verifyRemoteConfigRestart(_ session: RemoteConfigSession) async -> RemoteNetworkConfigDocument? {
        for attempt in 0..<Self.remoteConfigConfirmationAttempts {
            guard remoteConfigSession?.requestID == session.requestID else { return nil }
            try? await refreshRuntimeThrowing()

            var rpcURLs = [session.rpcURL]
            if let member = selectedLiveMemberStatuses.first(where: { $0.instanceID == session.instanceID }),
               let ip = member.copyableIPv4Address,
               let currentURL = URL(string: "tcp://\(ip):\(AppMode.defaultRPCListenPort)"),
               currentURL != session.rpcURL
            {
                rpcURLs.insert(currentURL, at: 0)
            }

            for rpcURL in rpcURLs {
                if let document = try? await EasyTierRemoteRPCClient(rpcURL: rpcURL, client: runtimeClient)
                    .getConfigDocument(instanceID: session.instanceID),
                   document.config == session.config
                {
                    return document
                }
            }

            if attempt + 1 < Self.remoteConfigConfirmationAttempts {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return nil
    }

    private func failRemoteConfigApply(requestID: UUID, message: String) {
        guard var current = remoteConfigSession, current.requestID == requestID else { return }
        current.applyState = .failed(message)
        remoteConfigSession = current
        recordNotice("Remote configuration apply failed: \(message)")
    }

    private func clearRemoteAppliedStateAfterDelay(requestID: UUID) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard var current = remoteConfigSession,
                  current.requestID == requestID,
                  current.applyState == .applied,
                  !current.hasUnsavedChanges
            else { return }
            current.applyState = .idle
            remoteConfigSession = current
        }
    }

    @discardableResult
    public func upsertRemoteHostnameRuntimeIntent(
        networkName: String,
        member: NetworkMemberStatus,
        desiredHostname: String
    ) async throws -> RuntimeIntent {
        try await upsertHostnameRuntimeIntent(
            target: RuntimeIntentTarget(
                networkName: networkName,
                instanceID: member.instanceID,
                peerID: member.peerID == "-" ? nil : member.peerID,
                recentHostname: member.hostname,
                recentIPv4: member.copyableIPv4Address,
                isLocal: false
            ),
            desiredHostname: desiredHostname,
            baseHostname: member.hostname
        )
    }

    public func setVPNOnDemandEnabled(_ enabled: Bool) async {
        do {
            var state = try stateForStorage()
            state.vpnOnDemandEnabled = enabled
            try await commitPersistenceState(state)
        } catch {
            setLastError(error)
            log("Could not save background runtime preference: \(error.localizedDescription)")
        }
    }

    public func applyMode(_ mode: AppMode) async {
        await applyPersistedMode(mode, magicDNSSettings: magicDNSSettings)
    }

    public func applyMode(_ mode: AppMode, magicDNSSettings: MagicDNSSettings) async {
        await applyPersistedMode(mode, magicDNSSettings: magicDNSSettings)
    }

    private func applyPersistedMode(_ mode: AppMode, magicDNSSettings: MagicDNSSettings) async {
        let rpcConfigurationChanged = self.mode != mode
        let magicDNSSuffixChanged = self.magicDNSSettings != magicDNSSettings
        let runningMagicDNSNames = runningMagicDNSConfigNames()
        do {
            var state = try stateForStorage()
            state.mode = mode
            state.magicDNSSettings = magicDNSSettings
            try await commitPersistenceState(state)
        } catch {
            setLastError(error)
            log("Settings save failed: \(error.localizedDescription)")
            return
        }
        if magicDNSSuffixChanged, !runningMagicDNSNames.isEmpty {
            recordNotice("Magic DNS suffix changed to \(magicDNSSettings.dnsSuffix). Restart \(runningMagicDNSNames.joined(separator: ", ")) to apply it.")
        }

        // The RPC portal is daemon-side. Only route it through the privileged
        // client when the helper is enabled; tests may configure it directly.
        if let helperRegistration, helperRegistration.state != .enabled {
            runtimeServiceConfigured = false
            if mode.rpcPortal == nil { log("RPC portal disabled.") }
            return
        }

        guard rpcConfigurationChanged || !runtimeServiceConfigured else { return }

        await busy {
            try await runtimeClient.configureRPCPortal(mode.rpcPortal, whitelist: mode.rpcPortalWhitelist)
            runtimeServiceConfigured = true
            if let rpcPortal = mode.rpcPortal {
                log("RPC portal listening: \(rpcPortal)")
            } else {
                log("RPC portal disabled.")
            }
        }

    }
    public var hasRunningMagicDNSNetworks: Bool {
        !runningMagicDNSConfigNames().isEmpty
    }

    public func exportSelectedTOML(
        options: TOMLExportOptions = TOMLExportOptions(),
        networkSecretInput: NetworkSecretInput? = nil
    ) async throws -> String {
        guard !selectedConfigIsRuntimeManaged else {
            throw EasyTierCoreError.operationFailed("Config Server-managed networks cannot be exported locally.")
        }
        guard let selectedConfig else { return "" }
        guard options.includeNetworkSecret else {
            return try NetworkConfigTOMLCodec.encode(
                Self.configWithoutNetworkSecret(selectedConfig),
                magicDNSSettings: magicDNSSettings,
                mode: .export
            )
        }
        let config: NetworkConfig
        if let networkSecretInput = normalizedNetworkSecretInput(networkSecretInput) {
            let authenticationGeneration = networkSecretAccessGeneration
            try await networkSecretStore.authenticate(
                for: selectedConfig,
                purpose: .export
            )
            if authenticationGeneration == networkSecretAccessGeneration,
               networkSecretInput.isSaved
            {
                cacheNetworkSecret(networkSecretInput.value, for: selectedConfig)
            }
            config = Self.config(
                selectedConfig,
                withNetworkSecret: networkSecretInput.value
            )
        } else {
            config = try await configWithKeychainSecret(
                selectedConfig,
                purpose: .export,
                reason: "Use the network secret for TOML export.",
                useSessionCache: false
            )
        }
        return try NetworkConfigTOMLCodec.encode(
            config,
            magicDNSSettings: magicDNSSettings,
            mode: .export
        )
    }

    public func importTOML(_ toml: String) async {
        do {
            let metadata = try NetworkConfigTOMLCodec.metadata(from: toml)
            var config = try NetworkConfigTOMLCodec.decode(toml)
            if configs.contains(where: { $0.id == config.instance_id }) {
                config.instance_id = UUID().uuidString.lowercased()
            }
            var state = try stateForStorage()
            if let suffix = metadata.magicDNSSuffix?.nilIfEmpty {
                let importedSettings = try MagicDNSSettings(dnsSuffix: suffix)
                if importedSettings != state.magicDNSSettings {
                    state.magicDNSSettings = importedSettings
                    recordNotice("Detected custom Magic DNS suffix \(importedSettings.dnsSuffix); saved it as this Mac's Magic DNS suffix.")
                }
            }
            let imported = try await configsWithSecretsStored([config])[0]
            state.configs.append(imported)
            state.selectedConfigID = imported.id
            try await commitPersistenceState(state)
            selectedTab = .config
            log("Imported \(imported.network_name).")
        } catch {
            let message = Self.errorMessage(for: error, toml: toml)
            setLastError(message, kind: Self.lastErrorKind(for: error))
            log("Import failed: \(message)")
        }
    }

    public func hasSavedNetworkSecret(for config: NetworkConfig) async throws -> Bool {
        try await networkSecretStore.containsSecret(for: config)
    }

    public func saveNetworkSecretToKeychain(_ secret: String, for config: NetworkConfig) async throws {
        guard let secret = secret.nilIfEmpty else { return }
        let authenticationGeneration = networkSecretAccessGeneration
        do {
            try await networkSecretStore.save(secret, for: config, purpose: .update)
            if authenticationGeneration == networkSecretAccessGeneration {
                cacheNetworkSecret(secret, for: config)
            }
        } catch {
            if authenticationGeneration == networkSecretAccessGeneration {
                clearCachedNetworkSecret(for: config)
            }
            throw error
        }
    }

    public func removeNetworkSecretFromKeychain(for config: NetworkConfig) async throws {
        try await networkSecretStore.deleteSecret(for: config, purpose: .delete)
        clearCachedNetworkSecret(for: config)
    }

    public func revealNetworkSecret(for config: NetworkConfig) async throws -> String? {
        try await configWithKeychainSecret(
            config,
            purpose: .reveal,
            reason: "Unlock the saved network secret for \(config.network_name).",
            useSessionCache: false
        ).network_secret?.nilIfEmpty
    }

    public func networkSecretAuthenticationCapability() -> NetworkSecretAuthenticationCapability {
        networkSecretStore.authenticationCapability()
    }

    public func lockNetworkSecretSession() {
        invalidateSecretAuthenticationSession()
    }

    public func handleApplicationDidBecomeActive() {
        runtimeSession.setApplicationActive(true)
    }

    public func handleApplicationDidResignActive() {
        runtimeSession.setApplicationActive(false)
    }

    public func handleApplicationDidHide() {
        invalidateSecretAuthenticationSession()
        runtimeSession.setApplicationActive(false)
    }

    public func startPolling() {
        runtimeSession.startPolling(
            refresh: { [weak self] in await self?.refreshRuntime() },
            handleWillSleep: { [weak self] in self?.handleSystemWillSleep() },
            handleSessionResign: { [weak self] in self?.handleUserSessionDidResignActive() },
            handleDidWake: { [weak self] in await self?.handleSystemDidWake() }
        )
    }

    public func stopPolling() {
        runtimeSession.stopPolling()
    }

    public func pausePolling() {
        runtimeSession.pausePolling()
    }

    public func resumePolling() {
        runtimeSession.resumePolling()
    }

    package func setRuntimePresentationActivity(_ activity: RuntimePresentationActivity) {
        guard runtimePresentationActivity != activity else { return }
        let previous = runtimePresentationActivity
        runtimePresentationActivity = activity

        if activity == .suspended {
            runtimeSession.markTrafficBaselineResetNeeded()
        }

        if previous == .suspended, activity != .suspended {
            Task { @MainActor [weak self] in
                await self?.refreshRuntime()
            }
        }
    }

    func handleSystemWillSleep(now: Date = Date()) {
        invalidateSecretAuthenticationSession()
        let shouldScheduleRecovery = !runtimeMutationInProgress && !isQuitting
        let recoverableConfigIDs = shouldScheduleRecovery
            ? configs.filter { runtimeReadinessPhase(matching: $0) == .ready }.map(\.id)
            : []
        runtimeSession.handleSystemWillSleep(
            now: now,
            recoverableConfigIDs: recoverableConfigIDs,
            operationGeneration: shouldScheduleRecovery ? runtimeOperationGeneration : nil
        )
    }

    func handleUserSessionDidResignActive() {
        invalidateSecretAuthenticationSession()
    }

    func handleSystemDidWake(now: Date = Date()) async {
        let recoveryRequest = runtimeSession.wakeRecoveryRequest(now: now)
        await refreshRuntime()

        guard let recoveryRequest,
              runtimeOperationGeneration == recoveryRequest.expectedOperationGeneration,
              !runtimeMutationInProgress,
              !isQuitting
        else { return }

        await recoverPreviouslyRunningConfigsAfterWake(
            configIDs: recoveryRequest.configIDs,
            expectedGeneration: recoveryRequest.expectedOperationGeneration
        )
    }

    private func recoverPreviouslyRunningConfigsAfterWake(
        configIDs: [String],
        expectedGeneration: UInt64
    ) async {
        await withRuntimeMutation(ifGeneration: expectedGeneration) {
            guard !isQuitting else { return }
            let configsToRecover = configIDs.compactMap { id in
                configs.first { $0.id == id }
            }
            guard !configsToRecover.isEmpty else { return }

            await busy {
                for config in configsToRecover {
                    try await recoverConfigAfterWake(config)
                }
            }
        }
    }

    private func recoverConfigAfterWake(_ config: NetworkConfig) async throws {
        setRuntimeTransition(.restarting, for: config.instance_id)
        log("Recovering \(config.network_name) after system wake...")
        let runningInstance = runningInstance(matching: config)
        try validateConfigForCurrentRuntime(config, replacing: runningInstance)
        let keychainConfig = try await configWithKeychainSecret(
            config,
            purpose: .wakeRecovery,
            reason: "Use the network secret to recover \(config.network_name) after system wake."
        )
        let cleanConfig = Self.configWithoutReversedPortForwards(keychainConfig, fingerprints: reversedPortForwardFingerprints)
        do {
            try await ensureRuntimeServiceReady()
        } catch {
            runtimeSession.setPendingStartAfterApproval(Self.configWithoutNetworkSecret(cleanConfig))
            throw error
        }
        if let runningInstance {
            try await persistRuntimeHostname(from: runningInstance, forConfigID: config.instance_id)
            try await runtimeClient.stop(instanceNames: [runningInstance.name])
            runtimeSession.clearTrafficTracking(instanceName: runningInstance.name)
            runtimeSession.clearPendingStart(for: config)
        }
        guard !isQuitting else { return }
        try await runtimeClient.run(toml: try encodedTOML(for: cleanConfig))
        runtimeSession.recordPendingStart(for: config)
        log("Recovery start requested for \(config.network_name) after system wake.")
    }

    private func refreshRuntimeThrowing(allowDuringRuntimeMutation: Bool = false) async throws {
        guard allowDuringRuntimeMutation || !runtimeMutationInProgress else { return }
        let refreshSignpostID = EasyTierPerformanceSignposts.beginRuntimeRefresh()
        defer { EasyTierPerformanceSignposts.endRuntimeRefresh(refreshSignpostID) }
        runtimeRefreshRevision &+= 1
        let refreshRevision = runtimeRefreshRevision
        let operationGeneration = runtimeOperationGeneration
        guard let presentationChange = try await runtimeSession.refreshRuntime(
            currentInstances: instances,
            currentRuntimeDetails: runtimeDetails,
            currentStatusMetrics: statusMetricsByInstance,
            currentTrafficSamples: trafficSamplesByInstance,
            currentTrafficSamplingStatus: trafficSamplingStatusByInstance,
            currentMemberPresentation: runtimeMemberPresentation,
            selectedTab: selectedTab,
            presentationActivity: runtimePresentationActivity,
            shouldApply: { [weak self] in
                guard let self else { return false }
                return refreshRevision > self.lastAppliedRuntimeRefreshRevision
                    && self.runtimeOperationGeneration == operationGeneration
                    && (allowDuringRuntimeMutation || !self.runtimeMutationInProgress)
            }
        ) else { return }
        guard refreshRevision > lastAppliedRuntimeRefreshRevision,
              runtimeOperationGeneration == operationGeneration,
              allowDuringRuntimeMutation || !runtimeMutationInProgress
        else { return }
        lastAppliedRuntimeRefreshRevision = refreshRevision
        let publishSignpostID = presentationChange.shouldRefreshSelectedSnapshots
            ? EasyTierPerformanceSignposts.beginRuntimePublish()
            : nil
        isPublishingRuntimePresentation = true
        if presentationChange.shouldPublishMemberPresentation {
            runtimeMemberPresentation = presentationChange.state.memberPresentation
        }
        if presentationChange.shouldPublishRuntimeDetails {
            runtimeDetails = presentationChange.state.runtimeDetails
        }
        if presentationChange.shouldPublishInstances {
            instances = presentationChange.state.instances
        }
        if presentationChange.shouldPublishStatusMetrics {
            statusMetricsByInstance = presentationChange.state.statusMetricsByInstance
        }
        if presentationChange.shouldPublishTrafficSamples {
            trafficSamplesByInstance = presentationChange.state.trafficSamplesByInstance
        }
        if presentationChange.shouldPublishTrafficSamplingStatus {
            trafficSamplingStatusByInstance = presentationChange.state.trafficSamplingStatusByInstance
        }
        isPublishingRuntimePresentation = false
        if presentationChange.shouldRefreshSelectedSnapshots {
            refreshSelectedRuntimeSnapshots()
        }
        if let publishSignpostID {
            EasyTierPerformanceSignposts.endRuntimePublish(publishSignpostID)
        }
        // A mutation's authoritative collect must not hold the control-plane
        // FIFO while hostname intent RPCs are retried. Normal polling performs
        // that reconciliation on the next refresh.
        if !allowDuringRuntimeMutation {
            await reconcileRuntimeIntents()
        }
    }

    private func reconcileRuntimeIntents() async {
        let ids = runtimeIntents.map(\.id)
        for id in ids {
            await reconcileHostnameIntent(id: id)
        }
        await cleanupExpiredIntents()
    }

    private func cleanupExpiredIntents() async {
        do {
            var state = try stateForStorage()
            guard RuntimeIntentReconciler.removeExpired(from: &state.runtimeIntents) else { return }
            try await commitPersistenceState(state)
        } catch {
            setLastError(error)
            log("Could not remove expired runtime intents: \(error.localizedDescription)")
        }
    }

    private func reconcileHostnameIntent(id: String, force: Bool = false) async {
        guard let intent = runtimeIntents.first(where: { $0.id == id }) else { return }
        let observation = runtimeObservation(for: intent.target)
        switch RuntimeIntentReconciler.reconciliation(for: intent, observation: observation, force: force) {
        case .ignore:
            return
        case .unreachable:
            await setRuntimeIntentStatus(id, .unreachable)
        case .applied:
            guard let observation else { return }
            await updateRuntimeIntent(id: id) { intent in
                intent.target.recentHostname = observation.hostname
                intent.target.recentIPv4 = observation.ipv4
                intent.status = .applied
                intent.updatedAt = Date()
            }
        case let .conflict(currentHostname, baseHostname):
            guard let observation else { return }
            await setRuntimeIntentStatus(id, .conflict)
            recordNotice("Runtime intent conflict for \(observation.label). Remote hostname is \(currentHostname ?? "-"), expected base \(baseHostname ?? "-").")
        case let .apply(desiredHostname):
            guard let observation else { return }
            do {
                try await applyHostname(desiredHostname, to: observation)
                await updateRuntimeIntent(id: id) { intent in
                    intent.target.recentHostname = observation.hostname
                    intent.target.recentIPv4 = observation.ipv4
                    intent.status = .pending
                    intent.updatedAt = Date()
                }
            } catch {
                await setRuntimeIntentStatus(id, .unreachable)
                recordNotice("Runtime intent replay failed for \(observation.label): \(error.localizedDescription)")
            }
        }
    }

    private func runtimeObservation(for target: RuntimeIntentTarget) -> RuntimeIntentObservation? {
        if target.isLocal {
            guard let instance = instances.first(where: { instance in
                if let instanceID = target.instanceID, instance.instance_id == instanceID { return true }
                return instance.name == target.networkName
            }) else { return nil }
            let detail = runtimeDetails[instance.name]
            return RuntimeIntentObservation(
                instanceID: instance.instance_id,
                hostname: detail?.my_node_info?.hostname,
                ipv4: detail?.my_node_info?.displayIPv4,
                rpcURL: mode.localRPCURL,
                label: instance.name
            )
        }

        let candidateInstances = instances.filter { instance in
            instance.name == target.networkName || config(matching: instance)?.network_name == target.networkName
        }
        for instance in candidateInstances {
            let detail = runtimeDetails[instance.name]
            guard let member = (detail?.memberStatuses ?? instance.detail?.memberStatuses ?? []).first(where: { member in
                guard !member.isLocal else { return false }
                if let instanceID = target.instanceID, member.instanceID == instanceID { return true }
                if let peerID = target.peerID, member.peerID == peerID { return true }
                return false
            }) else { continue }

            let rpcURL = member.copyableIPv4Address.flatMap { URL(string: "tcp://\($0):\(AppMode.defaultRPCListenPort)") }
            guard let instanceID = member.instanceID else {
                log("observeRuntimeIntents: matched member for target \(target.networkName) has no instanceID; skipping to avoid identity mismatch")
                continue
            }
            return RuntimeIntentObservation(
                instanceID: instanceID,
                hostname: member.hostname,
                ipv4: member.copyableIPv4Address,
                rpcURL: rpcURL,
                label: member.hostname
            )
        }

        return nil
    }

    private func applyHostname(_ hostname: String, to observation: RuntimeIntentObservation) async throws {
        guard let rpcURL = observation.rpcURL else {
            throw EasyTierCoreError.invalidResponse("runtime RPC URL is missing")
        }
        guard !observation.instanceID.isEmpty else {
            throw EasyTierCoreError.invalidResponse("runtime RPC target is missing")
        }
        let transport = EasyTierCoreRPCTransport(client: runtimeClient, rpcURL: rpcURL)
        try await EasyTierRemoteRPCClient(transport: transport).patchHostname(
            instanceID: observation.instanceID,
            hostname: hostname
        )
    }

    private func updateRuntimeIntent(
        id: String,
        mutate: (inout RuntimeIntent) -> Void
    ) async {
        do {
            var state = try stateForStorage()
            guard RuntimeIntentReconciler.update(id: id, in: &state.runtimeIntents, mutate: mutate) else { return }
            try await commitPersistenceState(state)
        } catch {
            setLastError(error)
            log("Could not update runtime intent: \(error.localizedDescription)")
        }
    }

    private func setRuntimeIntentStatus(_ id: String, _ status: RuntimeIntentStatus) async {
        await updateRuntimeIntent(id: id) { intent in
            intent.status = status
            intent.updatedAt = Date()
        }
    }

    private func persistRuntimeHostname(from instance: NetworkInstance, forConfigID configID: String) async throws {
        guard let runtimeHostname = instance.detail?.my_node_info?.hostname?.trimmedNilIfEmpty else { return }
        var state = try stateForStorage()
        guard let index = state.configs.firstIndex(where: { $0.id == configID }) else { return }
        let storedHostname = state.configs[index].hostname?.trimmedNilIfEmpty
        guard storedHostname != runtimeHostname else { return }

        state.configs[index].hostname = runtimeHostname
        try await commitPersistenceState(state)
    }

    private func stateForStorage() throws -> WorkspacePersistenceState {
        let configs = configs.map(Self.configWithoutNetworkSecret)
        let selectedLocalConfigID = selectedConfigID.flatMap { selectedID in
            configs.contains(where: { $0.id == selectedID }) ? selectedID : nil
        }
        let persistedLocalConfigID = persistedSelectedConfigID.flatMap { selectedID in
            configs.contains(where: { $0.id == selectedID }) ? selectedID : nil
        }
        return WorkspacePersistenceState(
            configs: configs,
            selectedConfigID: selectedLocalConfigID ?? persistedLocalConfigID,
            mode: mode,
            vpnOnDemandEnabled: vpnOnDemandEnabled,
            runtimeIntents: runtimeIntents,
            reversedPortForwardFingerprints: reversedPortForwardFingerprints,
            magicDNSSettings: magicDNSSettings,
            peerSubscriptions: peerSubscriptions
        )
    }

    private func commitPersistenceState(_ state: WorkspacePersistenceState) async throws {
        do {
            try await database.saveWorkspace(state)
            applyPersistenceState(state)
            persistenceHealth = .ready
        } catch {
            persistenceHealth = .unavailable(PersistenceFailure(
                message: error.localizedDescription,
                databaseURL: database.databaseURL
            ))
            throw error
        }
    }

    private func applyPersistenceState(_ state: WorkspacePersistenceState) {
        let transientRuntimeSelection = selectedConfigIsRuntimeManaged
            && state.selectedConfigID == persistedSelectedConfigID
            ? selectedConfigID
            : nil
        configs = state.configs
        persistedSelectedConfigID = state.selectedConfigID
        selectedConfigID = transientRuntimeSelection ?? state.selectedConfigID
        mode = state.mode
        vpnOnDemandEnabled = state.vpnOnDemandEnabled
        runtimeIntents = state.runtimeIntents
        reversedPortForwardFingerprints = state.reversedPortForwardFingerprints
        magicDNSSettings = state.magicDNSSettings
        peerSubscriptions = state.peerSubscriptions
    }

    private func configsWithSecretsStored(_ configs: [NetworkConfig]) async throws -> [NetworkConfig] {
        var configs = configs
        for index in configs.indices {
            guard let secret = configs[index].network_secret?.nilIfEmpty else { continue }
            try await saveNetworkSecretToKeychain(secret, for: configs[index])
            configs[index].network_secret = nil
        }
        return configs
    }

    private func configWithKeychainSecret(
        _ config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose,
        reason: String,
        useSessionCache: Bool = true
    ) async throws -> NetworkConfig {
        guard config.network_secret?.nilIfEmpty == nil else { return config }
        if useSessionCache, let cachedSecret = cachedNetworkSecret(for: config) {
            return Self.config(config, withNetworkSecret: cachedSecret)
        }
        let authenticationGeneration = networkSecretAccessGeneration
        let result = try await networkSecretStore.secret(
            for: config,
            purpose: purpose,
            reason: reason
        )
        guard authenticationGeneration == networkSecretAccessGeneration else {
            throw CancellationError()
        }
        guard let result else { return config }
        cacheNetworkSecret(result, for: config)
        return Self.config(config, withNetworkSecret: result)
    }

    private func configWithResolvedNetworkSecret(
        _ config: NetworkConfig,
        input: NetworkSecretInput?,
        purpose: NetworkSecretAccessPurpose,
        reason: String
    ) async throws -> ResolvedNetworkSecretConfig {
        guard let input = normalizedNetworkSecretInput(input) else {
            return ResolvedNetworkSecretConfig(
                config: try await configWithKeychainSecret(
                    config,
                    purpose: purpose,
                    reason: reason
                ),
                outcome: .none
            )
        }

        switch input {
        case let .saved(secret):
            cacheNetworkSecret(secret, for: config)
            return ResolvedNetworkSecretConfig(
                config: Self.config(config, withNetworkSecret: secret),
                outcome: .none
            )
        case let .edited(secret):
            try await saveNetworkSecretToKeychain(secret, for: config)
            return ResolvedNetworkSecretConfig(
                config: Self.config(config, withNetworkSecret: secret),
                outcome: NetworkSecretOperationOutcome(didPersistEditedSecret: true)
            )
        }
    }

    private func normalizedNetworkSecretInput(
        _ input: NetworkSecretInput?
    ) -> NetworkSecretInput? {
        guard let input, let value = input.value.nilIfEmpty else { return nil }
        switch input {
        case .saved:
            return .saved(value)
        case .edited:
            return .edited(value)
        }
    }

    private func cachedNetworkSecret(for config: NetworkConfig) -> String? {
        guard cachedNetworkSecret?.namespace == Self.secretNamespace(for: config) else { return nil }
        return cachedNetworkSecret?.value
    }

    private func cacheNetworkSecret(_ secret: String, for config: NetworkConfig) {
        guard let secret = secret.nilIfEmpty else { return }
        cachedNetworkSecret = CachedNetworkSecret(
            namespace: Self.secretNamespace(for: config),
            value: secret
        )
    }

    private func clearCachedNetworkSecret(for config: NetworkConfig) {
        guard cachedNetworkSecret?.namespace == Self.secretNamespace(for: config) else { return }
        cachedNetworkSecret = nil
    }

    private static func config(
        _ config: NetworkConfig,
        withNetworkSecret secret: String
    ) -> NetworkConfig {
        var config = config
        config.network_secret = secret
        return config
    }

    private func invalidateSecretAuthenticationSession() {
        cachedNetworkSecret = nil
        networkSecretSessionRevision &+= 1
        networkSecretAccessGeneration &+= 1
        networkSecretStore.invalidateAuthenticationSession()
    }

    private static func secretNamespace(for config: NetworkConfig) -> String {
        config.instance_id
    }

    private func encodedTOML(for config: NetworkConfig) throws -> String {
        try NetworkConfigTOMLCodec.encode(config, magicDNSSettings: magicDNSSettings)
    }

    private func uniquelyMatchedInstance(named networkName: String) -> NetworkInstance? {
        let matchingConfigs = configs.filter { $0.network_name == networkName }
        guard matchingConfigs.count <= 1 else { return nil }

        let matches = instances.filter { instance in
            instance.name == networkName || instance.instance_id == networkName
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func uniquelyMatchedConfig(named networkName: String) -> NetworkConfig? {
        let matches = configs.filter { $0.network_name == networkName }
        return matches.count == 1 ? matches[0] : nil
    }

    private func runningMagicDNSConfigNames() -> [String] {
        configs
            .filter { $0.enable_magic_dns == true && runningInstance(matching: $0) != nil }
            .map(\.network_name)
            .sorted()
    }

    private func localConfig(matching instance: NetworkInstance) -> NetworkConfig? {
        if let byID = configs.first(where: { $0.instance_id == instance.instance_id }) { return byID }
        let matches = configs.filter { $0.network_name == instance.name }
        return matches.count == 1 ? matches[0] : nil
    }

    private func reconcileSelectedConfigWithRuntimeManagedConfigs() {
        let presented = presentedConfigs
        if let selectedConfigID, presented.contains(where: { $0.id == selectedConfigID }) { return }
        let persistedLocalConfigID = persistedSelectedConfigID.flatMap { selectedID in
            configs.contains(where: { $0.id == selectedID }) ? selectedID : nil
        }
        selectedConfigID = persistedLocalConfigID ?? configs.first?.id ?? runtimeManagedConfigs.first?.id
    }

    private func selectConfig(offset: Int) async {
        let configs = presentedConfigs
        guard !configs.isEmpty else {
            await selectConfig(id: nil)
            return
        }

        let count = configs.count
        let currentIndex = selectedConfigID.flatMap { selectedID in
            configs.firstIndex { $0.id == selectedID }
        }
        let baseIndex = currentIndex ?? (offset > 0 ? -1 : count)
        let nextIndex = (baseIndex + offset + count) % count
        let nextID = configs[nextIndex].id
        guard selectedConfigID != nextID else { return }

        await selectConfig(id: nextID)
    }

    @discardableResult
    private func busy(
        surfaceError: Bool = true,
        _ operation: () async throws -> Void
    ) async -> Error? {
        busyOperationCount += 1
        isBusy = true
        defer {
            busyOperationCount -= 1
            isBusy = busyOperationCount > 0
        }
        do {
            try await operation()
            return nil
        } catch {
            let wasCanceled = Self.isNetworkSecretAccessCancellation(error)
            if !wasCanceled, surfaceError || Self.lastErrorKind(for: error) != nil {
                setLastError(error)
            }
            if wasCanceled {
                log("Network secret access canceled.")
            } else {
                log("Error: \(Self.errorMessage(for: error))")
            }
            return error
        }
    }

    public static func isNetworkSecretAccessCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? NetworkSecretStoreError)?.isUserCancellation == true
    }

    private func setLastError(_ error: Error) {
        setLastError(Self.errorMessage(for: error), kind: Self.lastErrorKind(for: error))
    }

    private static func errorMessage(for error: Error, toml: String? = nil) -> String {
        if let tomlError = error as? TOMLDecodingError {
            let message = tomlError.description
            if case let .invalidSyntax(line, column, _) = tomlError,
               let toml,
               let character = tomlCharacterDescription(in: toml, line: line, column: column)
            {
                return "\(message). Character at line \(line), column \(column): \(character)"
            }
            return message
        }
        return error.localizedDescription
    }

    private static func tomlCharacterDescription(in toml: String, line: Int, column: Int) -> String? {
        let lines = toml.components(separatedBy: .newlines)
        guard line > 0, line <= lines.count, column > 0 else { return nil }

        let scalars = Array(lines[line - 1].unicodeScalars)
        let index = column - 1
        guard index < scalars.count else {
            return index == scalars.count ? "end of line" : nil
        }

        let scalar = scalars[index]
        let value = String(format: "U+%04X", scalar.value)
        switch scalar {
        case "\"":
            return #"double quote " (U+0022)"#
        case " ":
            return "space (\(value))"
        case "\t":
            return "tab (\(value))"
        default:
            return #""\#(String(scalar))" (\#(value))"#
        }
    }

    private func setLastError(_ message: String, kind: LastErrorKind? = nil) {
        lastErrorKind = kind
        lastError = message
    }

    private static func lastErrorKind(for error: Error) -> LastErrorKind? {
        switch error {
        case PrivilegedHelperError.needsRegistration:
            return .helperPermission
        case let PrivilegedHelperError.helperReported(payload) where payload.code == "helperRequiresApproval":
            return .helperPermission
        default:
            return nil
        }
    }

    private func log(_ message: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        logLines.insert(LogEntry(text: "[\(timestamp)] \(message)"), at: 0)
        if logLines.count > 300 { logLines.removeLast(logLines.count - 300) }
    }

    // MARK: - Peer Subscriptions

    public func addPeerSubscription(url: URL) async {
        do {
            let fetched = try await PeerSubscriptionLibrary.fetch(
                from: url,
                using: peerSubscriptionDataLoader
            )
            var state = try stateForStorage()
            state.peerSubscriptions.append(contentsOf: fetched.subscriptions)
            try await commitPersistenceState(state)
            log("Added \(fetched.subscriptions.count) subscription(s) from \(url.absoluteString).")
            logPeerSubscriptionIssues(fetched.issues, source: url.absoluteString)
        } catch {
            setLastError(error)
            log("Failed to fetch subscription from \(url.absoluteString): \(error.localizedDescription)")
        }
    }

    public func addPeerSubscription(json: String) async throws {
        let decoded = try PeerSubscriptionLibrary.decode(json)
        var state = try stateForStorage()
        state.peerSubscriptions.append(contentsOf: decoded.subscriptions)
        try await commitPersistenceState(state)
        log("Added \(decoded.subscriptions.count) subscription(s) from pasted JSON.")
        logPeerSubscriptionIssues(decoded.issues, source: "pasted JSON")
    }

    public func refreshPeerSubscriptions() async {
        guard peerSubscriptions.contains(where: { $0.subscriptionURL != nil }) else { return }
        isRefreshingPeerSubscriptions = true
        defer { isRefreshingPeerSubscriptions = false }

        let result = await PeerSubscriptionLibrary.refresh(
            peerSubscriptions,
            using: peerSubscriptionDataLoader
        )
        do {
            var state = try stateForStorage()
            state.peerSubscriptions = result.subscriptions
            try await commitPersistenceState(state)
        } catch {
            setLastError(error)
            log("Subscriptions refresh could not be saved: \(error.localizedDescription)")
            return
        }
        for failure in result.failures {
            log("Failed to refresh subscription from \(failure.url.absoluteString): \(failure.message)")
        }
        for issue in result.issues {
            log("Skipped subscription outbound \(issue.issue.outboundIndex + 1) from \(issue.url.absoluteString): \(issue.issue.message)")
        }
        log("Subscriptions refresh complete.")
    }

    private func logPeerSubscriptionIssues(_ issues: [PeerSubscriptionImportIssue], source: String) {
        for issue in issues {
            log("Skipped subscription outbound \(issue.outboundIndex + 1) from \(source): \(issue.message)")
        }
    }

    public func peerCardLatency(for card: PeerCard) -> Int? {
        PeerSubscriptionLibrary.latency(for: card, runtimeDetails: runtimeDetails)
    }

    public enum PeerCardMergeResult: Equatable {
        case added(count: Int)
        case alreadyPresent
        case noSelectedConfig
    }

    /// Checks how a card would merge against the currently selected config's peer_urls.
    /// Does NOT mutate state — the actual merge is performed by the view layer against its draft.
    public func previewPeerCardMerge(_ card: PeerCard) -> PeerCardMergeResult {
        guard let selectedID = selectedConfigID,
              let config = configs.first(where: { $0.id == selectedID })
        else {
            return .noSelectedConfig
        }
        let count = PeerSubscriptionLibrary.additionalURLCount(for: card, in: config)
        guard count > 0 else {
            return .alreadyPresent
        }
        return .added(count: count)
    }

    private func uniqueNetworkName() -> String {
        let base = "easytier"
        let existing = Set(configs.map(\.network_name))
        if !existing.contains(base) { return base }
        for index in 2...999 where !existing.contains("\(base)-\(index)") {
            return "\(base)-\(index)"
        }
        return "\(base)-\(UUID().uuidString.prefix(6))"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    private static let remoteConfigConfirmationAttempts = 12
}

public struct LogEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}
