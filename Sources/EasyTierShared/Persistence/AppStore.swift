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
            reconcileSelectedConfigWithRuntimeManagedConfigs(previousInstances: oldValue)
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
    public internal(set) var persistenceHealth: PersistenceHealth = .preparing
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
    @ObservationIgnored var statusMetricsByInstance: [String: [String: RuntimeMemberStatusMetricsSnapshot]] = [:]
    @ObservationIgnored var trafficSamplingStatusByInstance: [String: RuntimeTrafficSamplingStatus] = [:]
    @ObservationIgnored var runtimeMemberPresentation = RuntimeMemberPresentationState()
    public internal(set) var selectedStatusSnapshot: RuntimeStatusSnapshot = .empty
    public internal(set) var selectedTrafficSnapshot: RuntimeTrafficSnapshot = .empty
    public internal(set) var networkSecretSessionRevision: UInt64 = 0
    @ObservationIgnored var networkSecretAccessGeneration: UInt64 = 0
    @ObservationIgnored var cachedNetworkSecret: CachedNetworkSecret?
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
    public internal(set) var runtimeTransitionsByConfigID: [String: NetworkRuntimeTransition] = [:]

    /// Presentation-only scroll state. Runtime collection must continue while
    /// this is true so topology changes are not hidden behind a stale gesture.
    public var isAnyViewScrolling = false

    public static func portForwardFingerprint(for rule: PortForwardConfig) -> String {
        "\(rule.bind_ip):\(rule.bind_port)-\(rule.dst_ip):\(rule.dst_port)-\(rule.proto)"
    }

    let runtimeClient: any EasyTierCoreClient
    public let helperRegistration: HelperRegistrationService?
    let database: ApplicationDatabase
    let networkSecretStore: any NetworkSecretStore
    let peerSubscriptionDataLoader: any PeerSubscriptionDataLoading
    let systemSleepPreventer: any SystemSleepPreventing
    var lastErrorKind: LastErrorKind?

    @ObservationIgnored lazy var runtimeSession = RuntimeSessionController(
        runtimeClient: runtimeClient,
        helperRegistration: helperRegistration,
        systemSleepPreventer: systemSleepPreventer
    )
    @ObservationIgnored var isPublishingRuntimePresentation = false
    @ObservationIgnored var runtimeOperationGeneration: UInt64 = 0
    @ObservationIgnored var runtimeRefreshRevision: UInt64 = 0
    @ObservationIgnored var lastAppliedRuntimeRefreshRevision: UInt64 = 0
    @ObservationIgnored var runtimeMutationLocked = false
    @ObservationIgnored var runtimeMutationInProgress = false
    @ObservationIgnored var runtimePresentationActivity: RuntimePresentationActivity = .interactive
    @ObservationIgnored var runtimeMutationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored var busyOperationCount = 0
    @ObservationIgnored var runtimeServiceConfigured = false
    @ObservationIgnored var persistedSelectedConfigID: String?
    @ObservationIgnored package var runtimeEnvironmentDidChange: (@MainActor @Sendable () -> Void)?

    @ObservationIgnored public internal(set) var runtimeDetailsWriteCount = 0
    @ObservationIgnored public internal(set) var instancesWriteCount = 0
    @ObservationIgnored public internal(set) var trafficSamplesByInstanceWriteCount = 0

    struct CachedNetworkSecret {
        var namespace: String
        var value: String
    }

    struct RuntimeStartResult {
        var error: Error?
        var secretOutcome: NetworkSecretOperationOutcome
    }

    struct ConfigRestartOperationResult {
        var result: ConfigApplyResult
        var secretOutcome: NetworkSecretOperationOutcome
    }

    struct ResolvedNetworkSecretConfig {
        var config: NetworkConfig
        var outcome: NetworkSecretOperationOutcome
    }

    enum LastErrorKind { case helperPermission }

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

    func withRuntimeMutation(
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

    func setRuntimeTransition(
        _ transition: NetworkRuntimeTransition,
        for configID: String
    ) {
        runtimeTransitionsByConfigID[configID] = transition
        notifyRuntimeEnvironmentDidChange()
    }

    func notifyRuntimeEnvironmentDidChange() {
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

    func refreshSelectedRuntimeSnapshotsIfNeeded() {
        guard !isPublishingRuntimePresentation else { return }
        refreshSelectedRuntimeSnapshots()
    }

    func refreshSelectedRuntimeSnapshots() {
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

    func prepareRuntimeService(surfaceError: Bool) async -> Bool {
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

    func ensureRuntimeServiceReady() async throws {
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
}
