import Foundation
import Observation
import TOML

@MainActor
@Observable
public final class EasyTierAppStore {
    public var configs: [NetworkConfig] = [] {
        didSet { refreshSelectedRuntimeSnapshotsIfNeeded() }
    }
    public var selectedConfigID: String? {
        didSet {
            if oldValue != nil, oldValue != selectedConfigID {
                invalidateSecretAuthenticationSession()
            }
            refreshSelectedRuntimeSnapshotsIfNeeded()
        }
    }
    public var mode: AppMode = .default
    public var instances: [NetworkInstance] = [] {
        didSet {
            instancesWriteCount += 1
            refreshSelectedRuntimeSnapshotsIfNeeded()
        }
    }
    public var runtimeDetails: [String: NetworkInstanceRunningInfo] = [:] {
        didSet {
            runtimeDetailsWriteCount += 1
            refreshSelectedRuntimeSnapshotsIfNeeded()
        }
    }
    public var selectedTab: WorkspaceTab = .status
    public var logLines: [LogEntry] = []
    public var isBusy = false
    public var isQuitting = false
    public var lastError: String?
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
    public var runtimeIntents: [RuntimeIntent] = []
    public var reversedPortForwardFingerprints: [String: Set<String>] = [:]
    public var vpnOnDemandEnabled = false
    public var magicDNSSettings: MagicDNSSettings = .default
    public var remoteConfigSession: RemoteConfigSession?
    public var peerSubscriptions: [PeerSubscription] = []
    public var isRefreshingPeerSubscriptions = false
    public var pendingPeerCardMerge: PeerCard?

    /// Presentation-only scroll state. Runtime collection must continue while
    /// this is true so topology changes are not hidden behind a stale gesture.
    public var isAnyViewScrolling = false

    public static func portForwardFingerprint(for rule: PortForwardConfig) -> String {
        "\(rule.bind_ip):\(rule.bind_port)-\(rule.dst_ip):\(rule.dst_port)-\(rule.proto)"
    }

    private let privilegedClient: any EasyTierCoreClient
    private let inProcessClient: any EasyTierCoreClient
    public let helperRegistration: HelperRegistrationService?
    private let storage: EasyTierStorage
    private let networkSecretStore: any NetworkSecretStore
    private let systemSleepPreventer: any SystemSleepPreventing
    @ObservationIgnored private var pendingSecretReads: [String: PendingSecretRead] = [:]
    @ObservationIgnored private var secretReadRevisions: [String: UInt64] = [:]
    private var lastErrorKind: LastErrorKind?

    @ObservationIgnored private lazy var runtimeSession = RuntimeSessionController(
        privilegedClient: privilegedClient,
        inProcessClient: inProcessClient,
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

    @ObservationIgnored public private(set) var runtimeDetailsWriteCount = 0
    @ObservationIgnored public private(set) var instancesWriteCount = 0
    @ObservationIgnored public private(set) var trafficSamplesByInstanceWriteCount = 0

    private enum LastErrorKind { case helperPermission }

    private struct PendingSecretRead {
        let id: UUID
        let authenticationGeneration: UInt64
        let revision: UInt64
        let task: Task<String?, Error>
    }

    public func resetWriteCounters() {
        runtimeDetailsWriteCount = 0
        instancesWriteCount = 0
        trafficSamplesByInstanceWriteCount = 0
    }

    package init(
        privilegedClient: any EasyTierCoreClient = PrivilegedEasyTierClient(),
        inProcessClient: (any EasyTierCoreClient)? = nil,
        helperRegistration: HelperRegistrationService? = nil,
        storage: EasyTierStorage = .default,
        networkSecretStore: any NetworkSecretStore = SystemNetworkSecretStore(),
        systemSleepPreventer: any SystemSleepPreventing = IOKitSystemSleepPreventer()
    ) {
        self.privilegedClient = privilegedClient
        self.inProcessClient = inProcessClient ?? privilegedClient
        self.helperRegistration = helperRegistration
        self.storage = storage
        self.networkSecretStore = networkSecretStore
        self.systemSleepPreventer = systemSleepPreventer
    }

    /// Convenience initializer for tests that use one runtime client.
    package convenience init(
        client: any EasyTierCoreClient = PrivilegedEasyTierClient(),
        storage: EasyTierStorage = .isolatedForTesting(),
        networkSecretStore: any NetworkSecretStore = SystemNetworkSecretStore(),
        systemSleepPreventer: any SystemSleepPreventing = IOKitSystemSleepPreventer()
    ) {
        self.init(
            privilegedClient: client,
            inProcessClient: client,
            helperRegistration: nil,
            storage: storage,
            networkSecretStore: networkSecretStore,
            systemSleepPreventer: systemSleepPreventer
        )
    }

    private func client(for config: NetworkConfig) -> any EasyTierCoreClient {
        runtimeSession.client(for: config)
    }

    private func setRuntimeClientKind(for config: NetworkConfig) {
        runtimeSession.setClientKind(for: config)
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
    }

    public var selectedConfig: NetworkConfig? {
        get {
            guard let selectedConfigID else { return nil }
            return configs.first { $0.id == selectedConfigID }
        }
        set {
            guard let newValue else { return }
            if let index = configs.firstIndex(where: { $0.id == newValue.instance_id }) {
                configs[index] = newValue
            }
        }
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
        let instanceID = instance.instance_id
        let networkName = instance.name

        if let byID = configs.first(where: { $0.instance_id == instanceID }) { return byID }
        return uniquelyMatchedConfig(named: networkName)
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
        do {
            let loaded = try storage.load()
            let snapshot = loaded.snapshot
            configs = try configsWithSecretsStored(loaded.configs)
            runtimeIntents = snapshot.runtimeIntents
            reversedPortForwardFingerprints = snapshot.reversedPortForwardFingerprints
            vpnOnDemandEnabled = snapshot.vpnOnDemandEnabled
            magicDNSSettings = snapshot.magicDNSSettings
            mode = snapshot.mode
            peerSubscriptions = snapshot.peerSubscriptions
            if let lastSelectedConfigID = snapshot.lastSelectedConfigID,
               configs.contains(where: { $0.id == lastSelectedConfigID })
            {
                selectedConfigID = lastSelectedConfigID
            } else {
                selectedConfigID = configs.first?.id
            }
            saveInBackground()
            log("Loaded \(configs.count) saved network config(s).")
            if let recoveryMessage = loaded.recoveryMessage {
                setLastError(recoveryMessage)
                log(recoveryMessage)
            }
        } catch {
            if configs.isEmpty {
                configs = [NetworkConfig()]
                selectedConfigID = configs.first?.id
            }
            setLastError(error)
            log("Failed to load state: \(error.localizedDescription)")
        }
        await refreshRuntime()
        startPolling()
    }

    public func save() {
        do {
            let state = try stateForStorage()
            try storage.save(state.snapshot, configs: state.configs)
            if state.configs != configs {
                configs = state.configs
            }
        } catch {
            setLastError(error)
            log("Save failed: \(error.localizedDescription)")
        }
    }

    public func addConfig() {
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
        configs.append(config)
        selectedConfigID = config.id
        selectedTab = .config
        saveInBackground()
        log("Added \(config.network_name).")
    }

    public func saveInBackground() {
        let state: (snapshot: AppSnapshot, configs: [NetworkConfig])
        do {
            state = try stateForStorage()
        } catch {
            setLastError(error)
            log("Save failed: \(error.localizedDescription)")
            return
        }
        if state.configs != configs {
            configs = state.configs
        }
        let storage = self.storage
        Task.detached(priority: .background) {
            try? storage.save(state.snapshot, configs: state.configs)
        }
    }

    public func deleteSelectedConfig() async {
        await withRuntimeMutation {
            guard let selectedConfigID, let index = configs.firstIndex(where: { $0.id == selectedConfigID }) else { return }
            let config = configs[index]
            if let runningInstance = runningInstance(matching: config) {
                do {
                    try await client(for: config).stop(instanceNames: [runningInstance.name])
                    runtimeSession.clearTrafficTracking(instanceName: runningInstance.name)
                } catch {
                    setLastError(error)
                    log("Delete canceled because \(config.network_name) could not be stopped: \(error.localizedDescription)")
                    return
                }
            }
            runtimeSession.clearClientKind(for: config)
            runtimeSession.clearPendingStart(for: config)
            runtimeIntents.removeAll { intent in
                intent.target.isLocal && (intent.target.instanceID == config.instance_id || intent.target.networkName == config.network_name)
            }
            reversedPortForwardFingerprints.removeValue(forKey: config.instance_id)
            invalidatePendingSecretRead(for: config.network_name)
            let removedID = configs.remove(at: index).id
            let storage = self.storage
            Task.detached(priority: .background) {
                try? storage.deleteConfig(id: removedID)
            }
            let nextIndex = min(index, configs.count - 1)
            self.selectedConfigID = configs.isEmpty ? nil : configs[nextIndex].id
            saveInBackground()
        }
    }

    public func updateConfig(id: String, with config: NetworkConfig, saveImmediately: Bool = false) {
        guard let index = configs.firstIndex(where: { $0.id == id }) else { return }
        let oldConfig = configs[index]
        if oldConfig.network_name != config.network_name {
            migrateNetworkSecret(from: oldConfig, to: config)
        }
        configs[index] = config
        if saveImmediately {
            save()
        }
    }

    private func migrateNetworkSecret(from oldConfig: NetworkConfig, to newConfig: NetworkConfig) {
        invalidatePendingSecretRead(for: oldConfig.network_name)
        invalidatePendingSecretRead(for: newConfig.network_name)
        do {
            try networkSecretStore.migrateSecret(from: oldConfig, to: newConfig)
        } catch {
            log("Skipped keychain secret migration from \(oldConfig.network_name) to \(newConfig.network_name): \(error.localizedDescription)")
        }
    }

    public func selectPreviousConfig() {
        selectConfig(offset: -1)
    }

    public func selectNextConfig() {
        selectConfig(offset: 1)
    }

    public func runSelectedConfig(networkSecretOverride: String? = nil) async {
        await withRuntimeMutation {
            await runSelectedConfigWithoutMutationLock(networkSecretOverride: networkSecretOverride)
        }
    }

    private func runSelectedConfigWithoutMutationLock(networkSecretOverride: String? = nil) async {
        guard let config = selectedConfig else { return }
        _ = await runConfigWithoutMutationLock(config, networkSecretOverride: networkSecretOverride)
    }

    @discardableResult
    private func runConfigWithoutMutationLock(
        _ config: NetworkConfig,
        networkSecretOverride: String? = nil
    ) async -> Error? {
        guard !isQuitting else { return nil }
        guard runningInstance(matching: config) == nil else {
            log("Start skipped because \(config.network_name) is already tracked.")
            return nil
        }
        return await busy {
            log("Starting \(config.network_name)...")
            try validateConfigForCurrentRuntime(config)
            let keychainConfig = try await configWithResolvedNetworkSecret(
                config,
                override: networkSecretOverride,
                reason: "Use the network secret to start \(config.network_name).",
                persistOverride: true
            )
            let cleanConfig = Self.configWithoutReversedPortForwards(keychainConfig, fingerprints: reversedPortForwardFingerprints)
            if config.requiresTUN, let helperRegistration {
                do {
                    try await helperRegistration.ensureRegistered()
                } catch {
                    runtimeSession.setPendingStartAfterApproval(Self.configWithoutNetworkSecret(cleanConfig))
                    throw error
                }
            }
            guard !isQuitting else { return }
            try await client(for: config).run(toml: try encodedTOML(for: cleanConfig))
            setRuntimeClientKind(for: cleanConfig)
            runtimeSession.recordPendingStart(for: config)
            log("Start requested for \(config.network_name).")
        }
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
            await busy {
                let keychainConfig = try await configWithKeychainSecret(
                    config,
                    reason: "Use the network secret to start \(config.network_name) after helper approval."
                )
                try await client(for: config).run(toml: try encodedTOML(for: keychainConfig))
                setRuntimeClientKind(for: keychainConfig)
                runtimeSession.recordPendingStart(for: config)
                log("Start requested for \(config.network_name) after helper approval.")
            }
        }
    }

    public func stopSelectedConfig() async {
        await withRuntimeMutation {
            await stopSelectedConfigWithoutMutationLock()
        }
    }

    private func stopSelectedConfigWithoutMutationLock() async {
        guard let config = selectedConfig else { return }
        await busy {
            log("Stopping \(config.network_name)...")
            guard let runningInstance = runningInstance(matching: config) else {
                log("Stop skipped because \(config.network_name) is not running.")
                return
            }
            persistRuntimeHostname(from: runningInstance, forConfigID: config.instance_id)
            try await client(for: config).stop(instanceNames: [runningInstance.name])
            runtimeSession.clearTrafficTracking(instanceName: runningInstance.name)
            runtimeSession.clearPendingStart(for: config)
            runtimeSession.clearClientKind(for: config)
            log("Stopped \(config.network_name).")
        }
    }

    public func restartSelectedConfig(
        replacing instance: NetworkInstance,
        configID targetConfigID: String? = nil,
        networkSecretOverride: String? = nil
    ) async {
        _ = await restartConfig(
            replacing: instance,
            configID: targetConfigID,
            networkSecretOverride: networkSecretOverride
        )
    }

    public func applyConfigDraft(
        configID: String,
        draft: NetworkConfig,
        replacing instance: NetworkInstance?
    ) async -> ConfigApplyResult {
        guard configs.contains(where: { $0.id == configID }) else {
            return .failed("The network configuration no longer exists.")
        }

        let networkSecretOverride = draft.network_secret?.nilIfEmpty
        var persistedDraft = draft
        persistedDraft.network_secret = nil
        updateConfig(id: configID, with: persistedDraft, saveImmediately: true)
        guard let instance else { return .saved }
        return await restartConfig(
            replacing: instance,
            configID: configID,
            networkSecretOverride: networkSecretOverride,
            surfaceError: false
        )
    }

    private func restartConfig(
        replacing instance: NetworkInstance,
        configID targetConfigID: String? = nil,
        networkSecretOverride: String? = nil,
        surfaceError: Bool = true
    ) async -> ConfigApplyResult {
        guard let targetConfigID = targetConfigID ?? selectedConfigID else {
            return .failed("No network configuration is selected.")
        }
        var result: ConfigApplyResult = .failed("The network configuration is unavailable.")
        await withRuntimeMutation {
            guard !isQuitting else {
                result = .failed("EasyTier is quitting.")
                return
            }
            guard let config = configs.first(where: { $0.id == targetConfigID }) else { return }
            let error = await busy(surfaceError: surfaceError) {
                log("Restarting \(config.network_name)...")
                try validateConfigForCurrentRuntime(config, replacing: instance)
                let keychainConfig = try await configWithResolvedNetworkSecret(
                    config,
                    override: networkSecretOverride,
                    reason: "Use the network secret to restart \(config.network_name).",
                    persistOverride: true
                )
                let cleanConfig = Self.configWithoutReversedPortForwards(keychainConfig, fingerprints: reversedPortForwardFingerprints)
                let targetClient = client(for: config)
                try await targetClient.validate(toml: try encodedTOML(for: cleanConfig))
                guard !isQuitting else { return }
                try await targetClient.stop(instanceNames: [instance.name])
                runtimeSession.clearTrafficTracking(instanceName: instance.name)
                runtimeSession.clearPendingStart(for: config)
                if config.requiresTUN, let helperRegistration {
                    do {
                        try await helperRegistration.ensureRegistered()
                    } catch {
                        runtimeSession.setPendingStartAfterApproval(Self.configWithoutNetworkSecret(cleanConfig))
                        throw error
                    }
                }
                guard !isQuitting else { return }
                try await targetClient.run(toml: try encodedTOML(for: cleanConfig))
                setRuntimeClientKind(for: cleanConfig)
                runtimeSession.recordPendingStart(for: config)
                log("Restart requested for \(config.network_name).")
            }
            result = error.map { .failed(Self.errorMessage(for: $0)) } ?? .restarted
        }
        return result
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

    private static func configWithoutNetworkSecret(_ config: NetworkConfig) -> NetworkConfig {
        var config = config
        config.network_secret = nil
        return config
    }

    public func toggleSelectedConfigConnection() async {
        await withRuntimeMutation {
            if selectedConfigCanStop {
                await stopSelectedConfigWithoutMutationLock()
            } else {
                await runSelectedConfigWithoutMutationLock()
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
            await busy {
                // Stop privileged instances via the daemon's retain-by-allowlist call.
                if runtimeSession.hasPrivilegedInstances(in: instances) {
                    do {
                        try await privilegedClient.retain(instanceNames: [])
                    } catch {
                        log("Failed to retain privileged instance allowlist during stopAll: \(error.localizedDescription)")
                    }
                }
                // Stop in-process instances individually (no retain API).
                let inProcessInstanceNames = runtimeSession.inProcessInstanceNames(in: instances)
                if !inProcessInstanceNames.isEmpty {
                    do {
                        try await inProcessClient.stop(instanceNames: inProcessInstanceNames)
                    } catch {
                        log("Failed to stop in-process instances \(inProcessInstanceNames) during stopAll: \(error.localizedDescription)")
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
            await withRuntimeMutation {
                await stopInProcessInstancesBeforeQuit()
            }
            log("Quit requested with VPN On Demand enabled; leaving EasyTier network running.")
            stopPolling()
            return
        }

        await stopAll()
        stopPolling()
        if let shutdownClient = privilegedClient as? EasyTierHelperShutdownClient {
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

        if let shutdownClient = privilegedClient as? EasyTierHelperShutdownClient {
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
                if await runConfigWithoutMutationLock(config) != nil {
                    log("Could not restore \(config.network_name) after software update.")
                }
            }
        }
    }

    private func stopInProcessInstancesBeforeQuit() async {
        let names = instances.compactMap { instance -> String? in
            guard let config = config(matching: instance), !config.requiresTUN else { return nil }
            return instance.name
        }
        guard !names.isEmpty else { return }

        do {
            try await inProcessClient.stop(instanceNames: names)
            log("Stopped \(names.count) in-process EasyTier instance(s); VPN On Demand only keeps helper-backed VPN instances running after quit.")
        } catch {
            log("Could not stop in-process EasyTier instance(s) before quit: \(error.localizedDescription)")
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
    ) -> RuntimeIntent {
        let desiredHostname = desiredHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let intent = RuntimeIntent(
            target: target,
            desiredHostname: desiredHostname,
            baseHostname: baseHostname?.trimmedNilIfEmpty,
            status: .pending
        )

        let resolved = RuntimeIntentReconciler.upsert(intent, in: &runtimeIntents)
        save()
        return resolved
    }

    public func markRuntimeIntent(_ id: String, status: RuntimeIntentStatus) {
        updateRuntimeIntent(id: id) { intent in
            intent.status = status
            intent.updatedAt = Date()
        }
    }

    public func useRemoteValue(forRuntimeIntent id: String) {
        runtimeIntents.removeAll { $0.id == id }
        save()
    }

    public func keepRuntimeIntentPending(_ id: String) {
        markRuntimeIntent(id, status: .pending)
    }

    public func reapplyRuntimeIntent(_ id: String) async {
        guard let intent = runtimeIntents.first(where: { $0.id == id }),
              let observation = runtimeObservation(for: intent.target)
        else {
            markRuntimeIntent(id, status: .unreachable)
            return
        }

        updateRuntimeIntent(id: id) { intent in
            intent.baseHostname = observation.hostname
            intent.status = .pending
            intent.updatedAt = Date()
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
        let intent = upsertHostnameRuntimeIntent(
            target: target,
            desiredHostname: desiredHostname,
            baseHostname: baseHostname
        )

        guard let observation = runtimeObservation(for: target) else {
            markRuntimeIntent(intent.id, status: .unreachable)
            recordNotice("Saved hostname for \(runningInstance.name). Runtime RPC is unavailable; it will be retried while this GUI is open.")
            return
        }

        do {
            try await applyHostname(desiredHostname, to: observation)
            markRuntimeIntent(intent.id, status: .pending)
            recordNotice("Runtime hostname patch sent for \(runningInstance.name).")
        } catch {
            markRuntimeIntent(intent.id, status: .unreachable)
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
            client: EasyTierRemoteRPCClient(rpcURL: prepared.rpcURL, client: privilegedClient)
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
        let rpcClient = EasyTierRemoteRPCClient(rpcURL: applying.rpcURL, client: privilegedClient)

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
                if let document = try? await EasyTierRemoteRPCClient(rpcURL: rpcURL, client: privilegedClient)
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
    ) -> RuntimeIntent {
        upsertHostnameRuntimeIntent(
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

    public func applyMode(_ mode: AppMode) async {
        self.mode = mode
        save()

        // The RPC portal is daemon-side. Only route it through the privileged
        // client when the helper is enabled; tests may configure it directly.
        if let helperRegistration, helperRegistration.state != .enabled {
            if mode.rpcPortal == nil { log("RPC portal disabled.") }
            return
        }

        await busy {
            try await privilegedClient.configureRPCPortal(mode.rpcPortal, whitelist: mode.rpcPortalWhitelist)
            if let rpcPortal = mode.rpcPortal {
                log("RPC portal listening: \(rpcPortal)")
            } else {
                log("RPC portal disabled.")
            }
        }

    }

    public func applyMode(_ mode: AppMode, magicDNSSettings: MagicDNSSettings) async {
        let magicDNSSuffixChanged = self.magicDNSSettings != magicDNSSettings
        let runningMagicDNSNames = runningMagicDNSConfigNames()
        self.magicDNSSettings = magicDNSSettings
        if magicDNSSuffixChanged, !runningMagicDNSNames.isEmpty {
            recordNotice("Magic DNS suffix changed to \(magicDNSSettings.dnsSuffix). Restart \(runningMagicDNSNames.joined(separator: ", ")) to apply it.")
        }
        await applyMode(mode)
    }

    public func exportSelectedTOML(networkSecretOverride: String? = nil) async throws -> String {
        guard let selectedConfig else { return "" }
        let config = try await configWithResolvedNetworkSecret(
            selectedConfig,
            override: networkSecretOverride,
            reason: "Use the network secret for TOML export."
        )
        return try encodedTOML(for: config)
    }

    public func importTOML(_ toml: String) {
        do {
            let metadata = try NetworkConfigTOMLCodec.metadata(from: toml)
            var config = try NetworkConfigTOMLCodec.decode(toml)
            if configs.contains(where: { $0.id == config.instance_id }) {
                config.instance_id = UUID().uuidString.lowercased()
            }
            if let suffix = metadata.magicDNSSuffix?.nilIfEmpty {
                let importedSettings = try MagicDNSSettings(dnsSuffix: suffix)
                if importedSettings != magicDNSSettings {
                    magicDNSSettings = importedSettings
                    recordNotice("Detected custom Magic DNS suffix \(importedSettings.dnsSuffix); saved it as this Mac's Magic DNS suffix.")
                }
            }
            let imported = try configsWithSecretsStored([config])[0]
            configs.append(imported)
            selectedConfigID = imported.id
            selectedTab = .config
            save()
            log("Imported \(imported.network_name).")
        } catch {
            let message = Self.errorMessage(for: error, toml: toml)
            setLastError(message, kind: Self.lastErrorKind(for: error))
            log("Import failed: \(message)")
        }
    }

    public func hasSavedNetworkSecret(for config: NetworkConfig) async throws -> Bool {
        let store = networkSecretStore
        return try await Task.detached { @Sendable in
            try store.containsSecret(for: config)
        }.value
    }

    public func saveNetworkSecretToKeychain(_ secret: String, for config: NetworkConfig) async throws {
        guard let secret = secret.nilIfEmpty else { return }
        invalidatePendingSecretRead(for: config.network_name)
        let store = networkSecretStore
        try await Task.detached { @Sendable in
            try store.save(secret, for: config)
        }.value
    }

    public func removeNetworkSecretFromKeychain(for config: NetworkConfig) async throws {
        invalidatePendingSecretRead(for: config.network_name)
        let store = networkSecretStore
        try await Task.detached { @Sendable in
            try store.deleteSecret(for: config)
        }.value
    }

    public func revealNetworkSecret(for config: NetworkConfig) async throws -> String? {
        try await configWithKeychainSecret(
            config,
            reason: "Unlock the saved network secret for \(config.network_name)."
        ).network_secret?.nilIfEmpty
    }

    public func lockNetworkSecretSession() {
        invalidateSecretAuthenticationSession()
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
        log("Recovering \(config.network_name) after system wake...")
        let runningInstance = runningInstance(matching: config)
        try validateConfigForCurrentRuntime(config, replacing: runningInstance)
        let keychainConfig = try await configWithKeychainSecret(config, reason: "Use the network secret to recover \(config.network_name) after system wake.")
        let cleanConfig = Self.configWithoutReversedPortForwards(keychainConfig, fingerprints: reversedPortForwardFingerprints)
        let targetClient = client(for: config)

        if let runningInstance {
            persistRuntimeHostname(from: runningInstance, forConfigID: config.instance_id)
            try await targetClient.stop(instanceNames: [runningInstance.name])
            runtimeSession.clearTrafficTracking(instanceName: runningInstance.name)
            runtimeSession.clearPendingStart(for: config)
        }
        if config.requiresTUN, let helperRegistration {
            do {
                try await helperRegistration.ensureRegistered()
            } catch {
                runtimeSession.setPendingStartAfterApproval(Self.configWithoutNetworkSecret(cleanConfig))
                throw error
            }
        }
        guard !isQuitting else { return }
        try await targetClient.run(toml: try encodedTOML(for: cleanConfig))
        setRuntimeClientKind(for: cleanConfig)
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
        cleanupExpiredIntents()
    }

    private func cleanupExpiredIntents() {
        if RuntimeIntentReconciler.removeExpired(from: &runtimeIntents) {
            saveInBackground()
        }
    }

    private func reconcileHostnameIntent(id: String, force: Bool = false) async {
        guard let intent = runtimeIntents.first(where: { $0.id == id }) else { return }
        let observation = runtimeObservation(for: intent.target)
        switch RuntimeIntentReconciler.reconciliation(for: intent, observation: observation, force: force) {
        case .ignore:
            return
        case .unreachable:
            setRuntimeIntentStatus(id, .unreachable)
        case .applied:
            guard let observation else { return }
            updateRuntimeIntent(id: id) { intent in
                intent.target.recentHostname = observation.hostname
                intent.target.recentIPv4 = observation.ipv4
                intent.status = .applied
                intent.updatedAt = Date()
            }
        case let .conflict(currentHostname, baseHostname):
            guard let observation else { return }
            setRuntimeIntentStatus(id, .conflict)
            recordNotice("Runtime intent conflict for \(observation.label). Remote hostname is \(currentHostname ?? "-"), expected base \(baseHostname ?? "-").")
        case let .apply(desiredHostname):
            guard let observation else { return }
            do {
                try await applyHostname(desiredHostname, to: observation)
                updateRuntimeIntent(id: id) { intent in
                    intent.target.recentHostname = observation.hostname
                    intent.target.recentIPv4 = observation.ipv4
                    intent.status = .pending
                    intent.updatedAt = Date()
                }
            } catch {
                setRuntimeIntentStatus(id, .unreachable)
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
        let transport = EasyTierCoreRPCTransport(client: privilegedClient, rpcURL: rpcURL)
        try await EasyTierRemoteRPCClient(transport: transport).patchHostname(
            instanceID: observation.instanceID,
            hostname: hostname
        )
    }

    private func updateRuntimeIntent(id: String, mutate: (inout RuntimeIntent) -> Void) {
        if RuntimeIntentReconciler.update(id: id, in: &runtimeIntents, mutate: mutate) {
            saveInBackground()
        }
    }

    private func setRuntimeIntentStatus(_ id: String, _ status: RuntimeIntentStatus) {
        updateRuntimeIntent(id: id) { intent in
            intent.status = status
            intent.updatedAt = Date()
        }
    }

    private func persistRuntimeHostname(from instance: NetworkInstance, forConfigID configID: String) {
        guard let runtimeHostname = instance.detail?.my_node_info?.hostname?.trimmedNilIfEmpty else { return }
        guard let index = configs.firstIndex(where: { $0.id == configID }) else { return }
        let storedHostname = configs[index].hostname?.trimmedNilIfEmpty
        guard storedHostname != runtimeHostname else { return }

        configs[index].hostname = runtimeHostname
        if selectedConfigID == configID {
            selectedConfigID = configs[index].id
        }
        save()
    }

    private func stateForStorage() throws -> (snapshot: AppSnapshot, configs: [NetworkConfig]) {
        let configs = try configsWithSecretsStored(configs)
        let snapshot = AppSnapshot(
            configIDs: configs.map(\.id),
            mode: mode,
            lastSelectedConfigID: selectedConfigID,
            vpnOnDemandEnabled: vpnOnDemandEnabled,
            runtimeIntents: runtimeIntents,
            reversedPortForwardFingerprints: reversedPortForwardFingerprints,
            magicDNSSettings: magicDNSSettings,
            peerSubscriptions: peerSubscriptions
        )
        return (snapshot, configs)
    }

    private func configsWithSecretsStored(_ configs: [NetworkConfig]) throws -> [NetworkConfig] {
        var configs = configs
        for index in configs.indices {
            guard let secret = configs[index].network_secret?.nilIfEmpty else { continue }
            invalidatePendingSecretRead(for: configs[index].network_name)
            try networkSecretStore.save(secret, for: configs[index])
            configs[index].network_secret = nil
        }
        return configs
    }

    private func configWithKeychainSecret(_ config: NetworkConfig, reason: String) async throws -> NetworkConfig {
        guard config.network_secret?.nilIfEmpty == nil else { return config }
        let networkName = config.network_name
        let pendingRead: PendingSecretRead
        if let existing = pendingSecretReads[networkName],
           existing.authenticationGeneration == networkSecretSessionRevision,
           existing.revision == secretReadRevision(for: networkName)
        {
            pendingRead = existing
        } else {
            let store = networkSecretStore
            let task = Task.detached { @Sendable in
                try store.secret(for: config, reason: reason)
            }
            pendingRead = PendingSecretRead(
                id: UUID(),
                authenticationGeneration: networkSecretSessionRevision,
                revision: secretReadRevision(for: networkName),
                task: task
            )
            pendingSecretReads[networkName] = pendingRead
        }

        let secret: String?
        do {
            secret = try await pendingRead.task.value
        } catch {
            removePendingSecretReadIfMatching(pendingRead, for: networkName)
            throw error
        }
        removePendingSecretReadIfMatching(pendingRead, for: networkName)
        guard pendingRead.authenticationGeneration == networkSecretSessionRevision,
              pendingRead.revision == secretReadRevision(for: networkName)
        else {
            throw CancellationError()
        }
        guard let secret else { return config }
        var config = config
        config.network_secret = secret
        return config
    }

    private func configWithResolvedNetworkSecret(
        _ config: NetworkConfig,
        override: String?,
        reason: String,
        persistOverride: Bool = false
    ) async throws -> NetworkConfig {
        guard let override = override?.nilIfEmpty else {
            return try await configWithKeychainSecret(config, reason: reason)
        }
        if persistOverride {
            try await saveNetworkSecretToKeychain(override, for: config)
        }
        var config = config
        config.network_secret = override
        return config
    }

    private func secretReadRevision(for networkName: String) -> UInt64 {
        secretReadRevisions[networkName, default: 0]
    }

    private func invalidatePendingSecretRead(for networkName: String) {
        secretReadRevisions[networkName, default: 0] &+= 1
        pendingSecretReads.removeValue(forKey: networkName)?.task.cancel()
    }

    private func removePendingSecretReadIfMatching(_ pendingRead: PendingSecretRead, for networkName: String) {
        guard pendingSecretReads[networkName]?.id == pendingRead.id else { return }
        pendingSecretReads.removeValue(forKey: networkName)
    }

    private func invalidateSecretAuthenticationSession() {
        networkSecretSessionRevision &+= 1
        pendingSecretReads.values.forEach { $0.task.cancel() }
        pendingSecretReads.removeAll()
        networkSecretStore.invalidateAuthenticationSession()
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

    private func selectConfig(offset: Int) {
        guard !configs.isEmpty else {
            selectedConfigID = nil
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

        selectedConfigID = nextID
        save()
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
            let fetched = try await PeerSubscriptionLibrary.fetch(from: url)
            peerSubscriptions.append(contentsOf: fetched)
            saveInBackground()
            log("Added \(fetched.count) subscription(s) from \(url.absoluteString).")
        } catch {
            setLastError(error)
            log("Failed to fetch subscription from \(url.absoluteString): \(error.localizedDescription)")
        }
    }

    public func addPeerSubscription(json: String) throws {
        let decoded = try PeerSubscriptionLibrary.decode(json)
        peerSubscriptions.append(contentsOf: decoded)
        saveInBackground()
        log("Added \(decoded.count) subscription(s) from pasted JSON.")
    }

    public func refreshPeerSubscriptions() async {
        guard peerSubscriptions.contains(where: { $0.subscriptionURL != nil }) else { return }
        isRefreshingPeerSubscriptions = true
        defer { isRefreshingPeerSubscriptions = false }

        let result = await PeerSubscriptionLibrary.refresh(peerSubscriptions)
        peerSubscriptions = result.subscriptions
        for failure in result.failures {
            log("Failed to refresh subscription from \(failure.url.absoluteString): \(failure.message)")
        }
        saveInBackground()
        log("Subscriptions refresh complete.")
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
