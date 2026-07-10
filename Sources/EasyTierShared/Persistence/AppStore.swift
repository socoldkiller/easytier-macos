import Foundation
import Observation
import TOML

public struct RemoteConfigSession: Sendable {
    public let rpcURL: URL
    public let instanceID: String
    public let member: NetworkMemberStatus
    public var config: NetworkConfig
    public var originalConfig: NetworkConfig
    public var isLoading: Bool
    public var loadError: String?

    public var hasUnsavedChanges: Bool {
        config != originalConfig
    }

    package init(
        rpcURL: URL,
        instanceID: String,
        member: NetworkMemberStatus,
        config: NetworkConfig,
        originalConfig: NetworkConfig,
        isLoading: Bool,
        loadError: String?
    ) {
        self.rpcURL = rpcURL
        self.instanceID = instanceID
        self.member = member
        self.config = config
        self.originalConfig = originalConfig
        self.isLoading = isLoading
        self.loadError = loadError
    }
}

@MainActor
@Observable
public final class EasyTierAppStore {
    public var configs: [NetworkConfig] = [] {
        didSet { refreshSelectedRuntimeSnapshotsIfNeeded() }
    }
    public var selectedConfigID: String? {
        didSet { refreshSelectedRuntimeSnapshotsIfNeeded() }
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
    public var trafficSamplesByInstance: [String: [TrafficSample]] = [:] {
        didSet {
            trafficSamplesByInstanceWriteCount += 1
            refreshSelectedRuntimeSnapshotsIfNeeded()
        }
    }
    private var statusMetricsByInstance: [String: [String: RuntimeMemberStatusMetricsSnapshot]] = [:]
    @ObservationIgnored private var trafficSamplingStatusByInstance: [String: RuntimeTrafficSamplingStatus] = [:]
    public private(set) var selectedStatusSnapshot: RuntimeStatusSnapshot = .empty
    public private(set) var selectedTrafficSnapshot: RuntimeTrafficSnapshot = .empty
    public var runtimeIntents: [RuntimeIntent] = []
    public var reversedPortForwardFingerprints: [String: Set<String>] = [:]
    public var vpnOnDemandEnabled = false
    public var magicDNSSettings: MagicDNSSettings = .default
    public var remoteConfigSession: RemoteConfigSession?
    public var peerSubscriptions: [PeerSubscription] = []
    public var isRefreshingPeerSubscriptions = false
    public var pendingPeerCardMerge: PeerCard?

    /// Mirrors any in-app scroll phase. Polling briefly skips refresh while
    /// this is true so the main-thread SwiftUI transaction pass does not
    /// compete with scroll-driven layout work.
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
    private var secretCache: [String: String] = [:]
    private var lastErrorKind: LastErrorKind?

    @ObservationIgnored private lazy var runtimeSession = RuntimeSessionController(
        privilegedClient: privilegedClient,
        inProcessClient: inProcessClient,
        helperRegistration: helperRegistration,
        systemSleepPreventer: systemSleepPreventer
    )
    @ObservationIgnored private var isPublishingRuntimePresentation = false

    @ObservationIgnored public private(set) var runtimeDetailsWriteCount = 0
    @ObservationIgnored public private(set) var instancesWriteCount = 0
    @ObservationIgnored public private(set) var trafficSamplesByInstanceWriteCount = 0

    private enum LastErrorKind { case helperPermission }

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
        storage: EasyTierStorage = .default,
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

    public var selectedConfigIsRunning: Bool {
        selectedRunningInstance != nil
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

    public func instanceIsFullyConnected(_ instance: NetworkInstance) -> Bool {
        instance.isFullyConnected(expectRemotePeers: config(matching: instance)?.expectsRemotePeerConnection == true)
    }

    public var selectedRuntimeDetail: NetworkInstanceRunningInfo? {
        selectedStatusSnapshot.runtimeDetail
    }

    public var selectedMemberStatuses: [NetworkMemberStatus] {
        selectedStatusSnapshot.members
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
        let trafficSamples = instance.flatMap { trafficSamplesByInstance[$0.name] } ?? []
        let trafficSamplingStatus = instance.flatMap { trafficSamplingStatusByInstance[$0.name] }

        let statusSnapshot = RuntimeStatusSnapshot.build(
            selectedConfig: config,
            runningInstance: instance,
            runtimeDetail: detail,
            memberStatusMetricsByID: statusMetrics
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
        secretCache.removeValue(forKey: config.network_name)
        let removedID = configs.remove(at: index).id
        let storage = self.storage
        Task.detached(priority: .background) {
            try? storage.deleteConfig(id: removedID)
        }
        let nextIndex = min(index, configs.count - 1)
        self.selectedConfigID = configs.isEmpty ? nil : configs[nextIndex].id
        saveInBackground()
        await refreshRuntime()
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
        do {
            guard let secret = try networkSecretStore.secret(for: oldConfig, reason: nil) else { return }
            try networkSecretStore.save(secret, for: newConfig)
            try networkSecretStore.deleteSecret(for: oldConfig)
            secretCache[oldConfig.network_name] = nil
            secretCache[newConfig.network_name] = secret
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

    public func runSelectedConfig() async {
        guard let config = selectedConfig else { return }
        await busy {
            log("Starting \(config.network_name)...")
            try validateConfigForCurrentRuntime(config)
            let keychainConfig = try await configWithKeychainSecret(config, reason: "Use the network secret to start \(config.network_name).")
            let cleanConfig = Self.configWithoutReversedPortForwards(keychainConfig, fingerprints: reversedPortForwardFingerprints)
            if config.requiresTUN, let helperRegistration {
                do {
                    try await helperRegistration.ensureRegistered()
                } catch {
                    runtimeSession.setPendingStartAfterApproval(cleanConfig)
                    throw error
                }
            }
            try await client(for: config).run(toml: try encodedTOML(for: cleanConfig))
            setRuntimeClientKind(for: cleanConfig)
            runtimeSession.recordPendingStart(for: config)
            log("Started \(config.network_name).")
            try await refreshRuntimeThrowing()
            if var instance = selectedRunningInstance {
                instance.detail = selectedRuntimeDetail
                if let error = instance.runtimeErrorMessage ?? instance.listenerErrorFromEvents {
                    setLastError(error)
                }
            }
        }
    }

    /// Retry the most recent start after the user approved the privileged helper.
    public func retryStartAfterHelperApproval() async {
        guard let config = runtimeSession.takePendingStartAfterApproval() else { return }
        if let helperRegistration {
            await helperRegistration.refresh()
            guard helperRegistration.state == .enabled else {
                setLastError("Privileged helper is still not enabled. Approve EasyTier in System Settings > Login Items & Extensions, then try again.", kind: .helperPermission)
                return
            }
        }
        await busy {
            try await client(for: config).run(toml: try encodedTOML(for: config))
            setRuntimeClientKind(for: config)
            if let selectedConfig, selectedConfig.instance_id == config.instance_id {
                runtimeSession.recordPendingStart(for: selectedConfig)
            }
            log("Started \(config.network_name) after helper approval.")
            try await refreshRuntimeThrowing()
        }
    }

    public func stopSelectedConfig() async {
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
            try await refreshRuntimeThrowing()
        }
    }

    public func restartSelectedConfig(replacing instance: NetworkInstance) async {
        guard let config = selectedConfig else { return }
        await busy {
            log("Restarting \(config.network_name)...")
            try validateConfigForCurrentRuntime(config, replacing: instance)
            let keychainConfig = try await configWithKeychainSecret(config, reason: "Use the network secret to restart \(config.network_name).")
            let cleanConfig = Self.configWithoutReversedPortForwards(keychainConfig, fingerprints: reversedPortForwardFingerprints)
            let targetClient = client(for: config)
            try await targetClient.validate(toml: try encodedTOML(for: cleanConfig))
            try await targetClient.stop(instanceNames: [instance.name])
            runtimeSession.clearTrafficTracking(instanceName: instance.name)
            runtimeSession.clearPendingStart(for: config)
            if config.requiresTUN, let helperRegistration {
                do {
                    try await helperRegistration.ensureRegistered()
                } catch {
                    runtimeSession.setPendingStartAfterApproval(cleanConfig)
                    throw error
                }
            }
            try await targetClient.run(toml: try encodedTOML(for: cleanConfig))
            setRuntimeClientKind(for: cleanConfig)
            runtimeSession.recordPendingStart(for: config)
            log("Restarted \(config.network_name).")
            try await refreshRuntimeThrowing()
        }
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

    public func toggleSelectedConfigConnection() async {
        if selectedConfigIsRunning {
            await stopSelectedConfig()
        } else {
            await runSelectedConfig()
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
            try await refreshRuntimeThrowing()
        }
    }

    public func prepareForAppQuit() async {
        guard !isQuitting else { return }
        isQuitting = true

        if vpnOnDemandEnabled {
            await stopInProcessInstancesBeforeQuit()
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
            baseHostname: nonEmptyTrimmed(baseHostname),
            status: .pending
        )

        if let index = runtimeIntents.firstIndex(where: { $0.reconcileKey == intent.reconcileKey }) {
            var updated = intent
            updated.id = runtimeIntents[index].id
            runtimeIntents[index] = updated
        } else {
            runtimeIntents.append(intent)
        }
        save()
        return runtimeIntents.first { $0.reconcileKey == intent.reconcileKey } ?? intent
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
        guard let instanceID = member.instanceID,
              let ip = member.copyableIPv4Address,
              let rpcURL = URL(string: "tcp://\(ip):\(AppMode.defaultRPCListenPort)")
        else {
            remoteConfigSession = RemoteConfigSession(
                rpcURL: Self.placeholderRPCURL,
                instanceID: member.instanceID ?? "",
                member: member,
                config: NetworkConfig(),
                originalConfig: NetworkConfig(),
                isLoading: false,
                loadError: "Remote instance ID or virtual IP is unavailable for \(member.hostname)."
            )
            return
        }

        remoteConfigSession = RemoteConfigSession(
            rpcURL: rpcURL,
            instanceID: instanceID,
            member: member,
            config: NetworkConfig(),
            originalConfig: NetworkConfig(),
            isLoading: true,
            loadError: nil
        )

        do {
            let config = try await EasyTierRemoteRPCClient(rpcURL: rpcURL).getConfigParsed(instanceID: instanceID)
            remoteConfigSession?.config = config
            remoteConfigSession?.originalConfig = config
            remoteConfigSession?.isLoading = false
        } catch {
            remoteConfigSession?.isLoading = false
            remoteConfigSession?.loadError = error.localizedDescription
        }
    }

    public func clearRemoteConfigSession() {
        remoteConfigSession = nil
    }

    @discardableResult
    public func applyRemoteConfigPatch() async -> Bool {
        guard var session = remoteConfigSession, !session.isLoading, session.loadError == nil else {
            return false
        }
        guard session.hasUnsavedChanges else { return true }
        do {
            _ = try await EasyTierRemoteRPCClient(rpcURL: session.rpcURL).applyConfigPatch(
                instanceID: session.instanceID,
                config: session.config,
                original: session.originalConfig
            )
            session.originalConfig = session.config
            remoteConfigSession = session
            return true
        } catch {
            lastError = error.localizedDescription
            return false
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

    public func exportSelectedTOML() async throws -> String {
        guard let selectedConfig else { return "" }
        let config = try await configWithKeychainSecret(selectedConfig, reason: "Use the network secret for TOML export.")
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

    public func networkSecretCanAutofill(for config: NetworkConfig) async -> Bool {
        let store = networkSecretStore
        return await Task.detached { @Sendable in
            store.containsSecret(for: config) && store.canAutofillWithBiometrics()
        }.value
    }

    public func autofillNetworkSecret(for config: NetworkConfig) async -> String? {
        (try? await configWithKeychainSecret(config, reason: "Use Touch ID to fill the network secret for \(config.network_name).").network_secret?.nilIfEmpty)
    }

    public func revealNetworkSecret(for config: NetworkConfig) async throws -> String? {
        try await configWithKeychainSecret(config, reason: "Show the network secret for \(config.network_name).").network_secret?.nilIfEmpty
    }

    public func startPolling() {
        runtimeSession.startPolling(
            isScrolling: { [weak self] in self?.isAnyViewScrolling == true },
            refresh: { [weak self] in await self?.refreshRuntime() },
            clearSecretCache: { [weak self] in self?.clearSecretCache() },
            handleWillSleep: { [weak self] in self?.handleSystemWillSleep() },
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

    func handleSystemWillSleep(now: Date = Date()) {
        runtimeSession.handleSystemWillSleep(
            now: now,
            configs: configs,
            runningInstance: { [weak self] config in self?.runningInstance(matching: config) }
        )
    }

    func handleSystemDidWake(now: Date = Date()) async {
        let configIDsToRecover = runtimeSession.wakeRecoveryConfigIDs(now: now)
        await refreshRuntime()

        guard !configIDsToRecover.isEmpty else { return }

        await recoverPreviouslyRunningConfigsAfterWake(configIDs: configIDsToRecover)
    }

    private func clearSecretCache() {
        secretCache.removeAll()
    }

    private func recoverPreviouslyRunningConfigsAfterWake(configIDs: [String]) async {
        let configsToRecover = configIDs.compactMap { id in
            configs.first { $0.id == id }
        }
        guard !configsToRecover.isEmpty else { return }

        await busy {
            for config in configsToRecover {
                try await recoverConfigAfterWake(config)
            }
            try await refreshRuntimeThrowing()
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
                runtimeSession.setPendingStartAfterApproval(cleanConfig)
                throw error
            }
        }
        try await targetClient.run(toml: try encodedTOML(for: cleanConfig))
        setRuntimeClientKind(for: cleanConfig)
        runtimeSession.recordPendingStart(for: config)
        log("Recovered \(config.network_name) after system wake.")
    }

    private func refreshRuntimeThrowing() async throws {
        let presentationChange = try await runtimeSession.refreshRuntime(
            currentInstances: instances,
            currentRuntimeDetails: runtimeDetails,
            currentStatusMetrics: statusMetricsByInstance,
            currentTrafficSamples: trafficSamplesByInstance,
            currentTrafficSamplingStatus: trafficSamplingStatusByInstance,
            selectedTab: selectedTab
        )
        isPublishingRuntimePresentation = true
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
        refreshSelectedRuntimeSnapshots()
        await reconcileRuntimeIntents()
    }

    private func reconcileRuntimeIntents() async {
        let ids = runtimeIntents.map(\.id)
        for id in ids {
            await reconcileHostnameIntent(id: id)
        }
        cleanupExpiredIntents()
    }

    private func cleanupExpiredIntents() {
        let now = Date()
        let appliedExpiration = now.addingTimeInterval(-300)
        let unreachableExpiration = now.addingTimeInterval(-600)
        let maxIntents = 20

        runtimeIntents.removeAll { intent in
            if intent.status == .applied, intent.updatedAt < appliedExpiration {
                return true
            }
            if intent.status == .unreachable, intent.updatedAt < unreachableExpiration {
                return true
            }
            return false
        }

        if runtimeIntents.count > maxIntents {
            runtimeIntents = Array(runtimeIntents.suffix(maxIntents))
            saveInBackground()
        }
    }

    private func reconcileHostnameIntent(id: String, force: Bool = false) async {
        guard let intent = runtimeIntents.first(where: { $0.id == id }),
              let desiredHostname = nonEmptyTrimmed(intent.desiredHostname)
        else { return }

        guard let observation = runtimeObservation(for: intent.target) else {
            setRuntimeIntentStatus(id, .unreachable)
            return
        }

        let currentHostname = nonEmptyTrimmed(observation.hostname)
        if currentHostname == desiredHostname {
            updateRuntimeIntent(id: id) { intent in
                intent.target.recentHostname = observation.hostname
                intent.target.recentIPv4 = observation.ipv4
                intent.status = .applied
                intent.updatedAt = Date()
            }
            return
        }

        guard force || intent.status != .conflict else { return }

        let baseHostname = nonEmptyTrimmed(intent.baseHostname)
        guard force || currentHostname == baseHostname else {
            setRuntimeIntentStatus(id, .conflict)
            recordNotice("Runtime intent conflict for \(observation.label). Remote hostname is \(currentHostname ?? "-"), expected base \(baseHostname ?? "-").")
            return
        }

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
        guard let index = runtimeIntents.firstIndex(where: { $0.id == id }) else { return }
        var updated = runtimeIntents[index]
        mutate(&updated)
        guard runtimeIntents[index] != updated else { return }
        runtimeIntents[index] = updated
        saveInBackground()
    }

    private func setRuntimeIntentStatus(_ id: String, _ status: RuntimeIntentStatus) {
        updateRuntimeIntent(id: id) { intent in
            intent.status = status
            intent.updatedAt = Date()
        }
    }

    private func persistRuntimeHostname(from instance: NetworkInstance, forConfigID configID: String) {
        guard let runtimeHostname = nonEmptyTrimmed(instance.detail?.my_node_info?.hostname) else { return }
        guard let index = configs.firstIndex(where: { $0.id == configID }) else { return }
        let storedHostname = nonEmptyTrimmed(configs[index].hostname)
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
            try networkSecretStore.save(secret, for: configs[index])
            secretCache[configs[index].network_name] = secret
            configs[index].network_secret = nil
        }
        return configs
    }

    private func configWithKeychainSecret(_ config: NetworkConfig, reason: String) async throws -> NetworkConfig {
        guard config.network_secret?.nilIfEmpty == nil else { return config }
        if let cached = secretCache[config.network_name] {
            var config = config
            config.network_secret = cached
            return config
        }
        let store = networkSecretStore
        let secret = try await Task.detached { @Sendable in try store.secret(for: config, reason: reason) }.value
        guard let secret else { return config }
        secretCache[config.network_name] = secret
        var config = config
        config.network_secret = secret
        return config
    }

    private func encodedTOML(for config: NetworkConfig) throws -> String {
        try NetworkConfigTOMLCodec.encode(config, magicDNSSettings: magicDNSSettings)
    }

    private func nonEmptyTrimmed(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
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

    private func busy(_ operation: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            // Surface the error to the UI instead of suppressing helper-permission messages.
            setLastError(error)
            log("Error: \(Self.errorMessage(for: error))")
        }
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
            let (data, _) = try await URLSession.shared.data(from: url)
            let fetched = try PeerSubscriptionCodec.decode(data)
            var merged: [PeerSubscription] = []
            for var sub in fetched {
                sub.subscriptionURL = url
                sub.lastFetchedAt = Date()
                merged.append(sub)
            }
            peerSubscriptions.append(contentsOf: merged)
            saveInBackground()
            log("Added \(merged.count) subscription(s) from \(url.absoluteString).")
        } catch {
            setLastError(error)
            log("Failed to fetch subscription from \(url.absoluteString): \(error.localizedDescription)")
        }
    }

    public func addPeerSubscription(json: String) throws {
        let decoded = try PeerSubscriptionCodec.decode(json)
        peerSubscriptions.append(contentsOf: decoded)
        saveInBackground()
        log("Added \(decoded.count) subscription(s) from pasted JSON.")
    }

    public func refreshPeerSubscriptions() async {
        let urls = peerSubscriptions.compactMap { $0.subscriptionURL }
        guard !urls.isEmpty else { return }
        isRefreshingPeerSubscriptions = true
        defer { isRefreshingPeerSubscriptions = false }

        for url in urls {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let fetched = try PeerSubscriptionCodec.decode(data)
                for var sub in fetched {
                    sub.subscriptionURL = url
                    sub.lastFetchedAt = Date()
                    if let index = peerSubscriptions.firstIndex(where: { $0.id == sub.id }) {
                        peerSubscriptions[index] = sub
                    } else if let index = peerSubscriptions.firstIndex(where: { $0.subscriptionURL == url }) {
                        var existing = peerSubscriptions[index]
                        existing.cards = sub.cards
                        existing.lastFetchedAt = sub.lastFetchedAt
                        if !sub.name.isEmpty { existing.name = sub.name }
                        peerSubscriptions[index] = existing
                    }
                }
            } catch {
                log("Failed to refresh subscription from \(url.absoluteString): \(error.localizedDescription)")
            }
        }
        saveInBackground()
        log("Subscriptions refresh complete.")
    }

    public func peerCardLatency(for card: PeerCard) -> Int? {
        guard !card.urls.isEmpty else { return nil }
        for (_, detail) in runtimeDetails {
            guard let pairs = detail.peer_route_pairs else { continue }
            for pair in pairs {
                guard let peer = pair.peer, let conns = peer.conns else { continue }
                for conn in conns {
                    if let tunnel = conn.tunnel,
                       let local = tunnel.local_addr?.url,
                       card.matchesRuntimePeerURL(local) {
                        if let latencyUs = conn.stats?.latency_us {
                            return max(1, Int((Double(latencyUs) / 1000.0).rounded()))
                        }
                    }
                    if let tunnel = conn.tunnel,
                       let remote = tunnel.remote_addr?.url,
                       card.matchesRuntimePeerURL(remote) {
                        if let latencyUs = conn.stats?.latency_us {
                            return max(1, Int((Double(latencyUs) / 1000.0).rounded()))
                        }
                    }
                }
            }
        }
        return nil
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
        let existing = Set(config.peer_urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let toAdd = card.urls.filter { !existing.contains($0) }
        guard !toAdd.isEmpty else {
            return .alreadyPresent
        }
        return .added(count: toAdd.count)
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
    /// Sentinel RPC URL used when we cannot construct a real peer URL (e.g. the
    /// member's instance ID or virtual IP is missing). It is structurally valid
    /// so downstream code can pattern-match on `rpcURL` without crashing, and
    /// the matching `loadError` surfaces the actual reason to the UI.
    private static let placeholderRPCURL = URL(string: "tcp://0.0.0.0:0") ?? URL(fileURLWithPath: "/dev/null")
}

public struct LogEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

private struct RuntimeIntentObservation {
    var instanceID: String
    var hostname: String?
    var ipv4: String?
    var rpcURL: URL?
    var label: String
}
