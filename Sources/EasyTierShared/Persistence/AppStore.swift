import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class EasyTierAppStore {
    public var configs: [StoredNetworkConfig] = []
    public var selectedConfigID: String?
    public var mode: AppMode = .default
    public var instances: [NetworkInstance] = []
    public var runtimeDetails: [String: NetworkInstanceRunningInfo] = [:]
    public var selectedTab: WorkspaceTab = .status
    public var logLines: [LogEntry] = []
    public var isBusy = false
    public var isQuitting = false
    public var lastError: String?
    public var isShowingSettings = false
    public var isShowingAbout = false
    public var isShowingLinuxInstallGuide = false
    public var isConfigServerConnected = false
    public var trafficSamplesByInstance: [String: [TrafficSample]] = [:]
    public var runtimeIntents: [RuntimeIntent] = []
    public var reversedPortForwardFingerprints: [String: Set<String>] = [:]
    public var vpnOnDemandEnabled = false

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
    private var pollingTask: Task<Void, Never>?
    private var lastTrafficCounters: [String: (timestamp: Date, txBytes: Int64, rxBytes: Int64)] = [:]
    private var pendingStarts: [String: PendingNetworkStart] = [:]
    private var pollingEnabled: Bool = true
    private var instanceClientKind: [String: ClientKind] = [:]
    private var pendingStartAfterApproval: NetworkConfig?
    private var lastErrorKind: LastErrorKind?
    private var sleepStartedAt: Date?
    private var runningConfigIDsBeforeSleep: [String] = []
    private var sleepWakeNotificationObservers: [NSObjectProtocol] = []
    private var resignActiveObserver: NSObjectProtocol?
    private var wakeRecoveryTask: Task<Void, Never>?

    public enum ClientKind: Sendable { case inProcess, privileged }
    private enum LastErrorKind { case helperPermission }

    public init(
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

    /// Backwards-compatible single-client initializer (for tests).
    public convenience init(
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
        config.requiresTUN ? privilegedClient : inProcessClient
    }

    private func clientKind(for config: NetworkConfig) -> ClientKind {
        config.requiresTUN ? .privileged : .inProcess
    }

    public var selectedConfig: NetworkConfig? {
        get {
            guard let selectedConfigID else { return nil }
            return configs.first { $0.id == selectedConfigID }?.config
        }
        set {
            guard let newValue else { return }
            if let index = configs.firstIndex(where: { $0.id == newValue.instance_id }) {
                configs[index].config = newValue
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

        if let byID = configs.first(where: { stored in stored.config.instance_id == instanceID })?.config { return byID }
        return uniquelyMatchedConfig(named: networkName)
    }

    public func instanceIsFullyConnected(_ instance: NetworkInstance) -> Bool {
        instance.isFullyConnected(expectRemotePeers: config(matching: instance)?.expectsRemotePeerConnection == true)
    }

    public var selectedRuntimeDetail: NetworkInstanceRunningInfo? {
        guard let name = selectedRunningInstance?.name else { return nil }
        return runtimeDetails[name]
    }

    public var selectedMemberStatuses: [NetworkMemberStatus] {
        selectedRuntimeDetail?.memberStatuses ?? []
    }

    public var selectedTrafficSamples: [TrafficSample] {
        guard let name = selectedRunningInstance?.name else { return [] }
        return trafficSamplesByInstance[name] ?? []
    }

    public func load() async {
        do {
            let snapshot = try storage.load()
            configs = try configsWithSecretsStored(snapshot.configs)
            runtimeIntents = snapshot.runtimeIntents
            reversedPortForwardFingerprints = snapshot.reversedPortForwardFingerprints
            vpnOnDemandEnabled = snapshot.vpnOnDemandEnabled
            mode = snapshot.mode ?? .default
            if let lastSelectedConfigID = snapshot.lastSelectedConfigID,
               configs.contains(where: { $0.id == lastSelectedConfigID })
            {
                selectedConfigID = lastSelectedConfigID
            } else {
                selectedConfigID = configs.first?.id
            }
            saveInBackground()
            log("Loaded \(configs.count) saved network config(s).")
        } catch {
            if configs.isEmpty {
                configs = [StoredNetworkConfig(config: NetworkConfig())]
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
            let snapshot = try snapshotForStorage()
            try storage.save(snapshot)
            if snapshot.configs != configs {
                configs = snapshot.configs
            }
        } catch {
            setLastError(error)
            log("Save failed: \(error.localizedDescription)")
        }
    }

    public func addConfig() {
        let config = StoredNetworkConfig(config: NetworkConfig(network_name: uniqueNetworkName()))
        configs.append(config)
        selectedConfigID = config.id
        selectedTab = .config
        saveInBackground()
        log("Added \(config.config.network_name).")
    }

    public func saveInBackground() {
        let snapshot: AppSnapshot
        do {
            snapshot = try snapshotForStorage()
        } catch {
            setLastError(error)
            log("Save failed: \(error.localizedDescription)")
            return
        }
        if snapshot.configs != configs {
            configs = snapshot.configs
        }
        let storage = self.storage
        Task.detached(priority: .background) {
            try? storage.save(snapshot)
        }
    }

    public func deleteSelectedConfig() async {
        guard let selectedConfigID, let index = configs.firstIndex(where: { $0.id == selectedConfigID }) else { return }
        let config = configs[index].config
        if let runningInstance = runningInstance(matching: config) {
            do {
                try await client(for: config).stop(instanceNames: [runningInstance.name])
            } catch {
                setLastError(error)
                log("Delete canceled because \(config.network_name) could not be stopped: \(error.localizedDescription)")
                return
            }
        }
        instanceClientKind.removeValue(forKey: config.instance_id)
        clearPendingStart(for: config)
        runtimeIntents.removeAll { intent in
            intent.target.isLocal && (intent.target.instanceID == config.instance_id || intent.target.networkName == config.network_name)
        }
        reversedPortForwardFingerprints.removeValue(forKey: config.instance_id)
        secretCache.removeValue(forKey: config.network_name)
        let removed = configs.remove(at: index)
        let storage = self.storage
        Task.detached(priority: .background) {
            try? storage.deleteConfig(removed)
        }
        let nextIndex = min(index, configs.count - 1)
        self.selectedConfigID = configs.isEmpty ? nil : configs[nextIndex].id
        saveInBackground()
        await refreshRuntime()
    }

    public func updateSelectedConfig(_ config: NetworkConfig) {
        guard let selectedConfigID else { return }
        updateConfig(id: selectedConfigID, with: config, saveImmediately: true)
    }

    public func updateConfig(id: String, with config: NetworkConfig, saveImmediately: Bool = false) {
        guard let index = configs.firstIndex(where: { $0.id == id }) else { return }
        let oldConfig = configs[index].config
        if oldConfig.network_name != config.network_name {
            migrateNetworkSecret(from: oldConfig, to: config)
        }
        configs[index].config = config
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

    public func validateSelectedConfig() async {
        guard let config = selectedConfig else { return }
        await busy {
            try validateConfigForCurrentRuntime(config)
            let keychainConfig = try await configWithKeychainSecret(config, reason: "Use the network secret for validation.")
            try await client(for: config).validate(toml: try NetworkConfigTOMLCodec.encode(keychainConfig))
            log("Validated \(config.network_name).")
        }
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
                    pendingStartAfterApproval = cleanConfig
                    throw error
                }
            }
            try await client(for: config).run(config: cleanConfig)
            instanceClientKind[cleanConfig.instance_id] = clientKind(for: cleanConfig)
            recordPendingStart(for: config)
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
        guard let config = pendingStartAfterApproval else { return }
        pendingStartAfterApproval = nil
        if let helperRegistration {
            await helperRegistration.refresh()
            guard helperRegistration.state == .enabled else {
                setLastError("Privileged helper is still not enabled. Approve EasyTier in System Settings > Login Items & Extensions, then try again.", kind: .helperPermission)
                return
            }
        }
        await busy {
            try await client(for: config).run(config: config)
            instanceClientKind[config.instance_id] = clientKind(for: config)
            if let selectedConfig, selectedConfig.instance_id == config.instance_id {
                recordPendingStart(for: selectedConfig)
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
            clearPendingStart(for: config)
            instanceClientKind.removeValue(forKey: config.instance_id)
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
            try await targetClient.validate(toml: try NetworkConfigTOMLCodec.encode(cleanConfig))
            try await targetClient.stop(instanceNames: [instance.name])
            clearPendingStart(for: config)
            if config.requiresTUN, let helperRegistration {
                do {
                    try await helperRegistration.ensureRegistered()
                } catch {
                    pendingStartAfterApproval = cleanConfig
                    throw error
                }
            }
            try await targetClient.run(config: cleanConfig)
            instanceClientKind[cleanConfig.instance_id] = clientKind(for: cleanConfig)
            recordPendingStart(for: config)
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
            if instances.contains(where: { instanceClientKind[$0.instance_id] != .inProcess }) {
                try? await privilegedClient.retain(instanceNames: [])
            }
            // Stop in-process instances individually (no retain API).
            let inProcessInstanceNames = instances
                .filter { instanceClientKind[$0.instance_id] == .inProcess }
                .map(\.name)
            if !inProcessInstanceNames.isEmpty {
                try? await inProcessClient.stop(instanceNames: inProcessInstanceNames)
            }
            instanceClientKind.removeAll()
            pendingStarts.removeAll()
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

    public func clearHelperPermissionError() {
        // Retained as a no-op for callers that used to clear the old suppressed banner.
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
            kind: .hostname,
            desired: RuntimeIntentDesired(hostname: desiredHostname),
            base: RuntimeIntentBase(hostname: nonEmptyTrimmed(baseHostname)),
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
            intent.base.hostname = observation.hostname
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

    public func easyTierCoreVersion() async throws -> String {
        // Prefer the privileged client when enabled (it tracks the canonical core build);
        // fall back to the in-process client for no_tun-only sessions.
        if helperRegistration?.state == .enabled {
            return try await privilegedClient.version()
        }
        return try await inProcessClient.version()
    }

    public func applyMode(_ mode: AppMode) async {
        self.mode = mode
        save()

        // The RPC portal and config-server client are daemon-side concerns.
        // Only route them through the privileged client when it is enabled.
        // When helperRegistration is nil (e.g. testing), allow direct configuration.
        if let helperRegistration, helperRegistration.state != .enabled {
            if mode.rpcPortal == nil { log("RPC portal disabled.") }
            if mode.configServerURL == nil { isConfigServerConnected = false }
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

        if let url = mode.configServerURL {
            await busy {
                try await privilegedClient.startConfigServerClient(url: url)
                isConfigServerConnected = try await privilegedClient.isConfigServerClientConnected()
                log("Config server client started: \(url.absoluteString)")
            }
        } else {
            do {
                try await privilegedClient.stopConfigServerClient()
                isConfigServerConnected = false
            } catch {
                log("Config server stop failed: \(error.localizedDescription)")
            }
        }
    }

    public func exportSelectedTOML() async throws -> String {
        guard let selectedConfig else { return "" }
        let config = try await configWithKeychainSecret(selectedConfig, reason: "Use the network secret for TOML export.")
        return try NetworkConfigTOMLCodec.encode(config)
    }

    public func importTOML(_ toml: String) {
        do {
            var config = try NetworkConfigTOMLCodec.decode(toml)
            if configs.contains(where: { $0.id == config.instance_id }) {
                config.instance_id = UUID().uuidString.lowercased()
            }
            let stored = try configsWithSecretsStored([StoredNetworkConfig(config: config)])[0]
            configs.append(stored)
            selectedConfigID = stored.id
            selectedTab = .config
            save()
            log("Imported \(stored.config.network_name).")
        } catch {
            setLastError(error)
            log("Import failed: \(error.localizedDescription)")
        }
    }

    public func networkSecretIsSaved(for config: NetworkConfig) async -> Bool {
        let store = networkSecretStore
        return await Task.detached { @Sendable in store.containsSecret(for: config) }.value
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
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.pollingEnabled else { continue }
                await self.refreshRuntime()
            }
        }
        registerSleepWakeNotifications()
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        updateSystemSleepAssertion(for: [])
        unregisterSleepWakeNotifications()
    }

    public func pausePolling() {
        pollingEnabled = false
    }

    public func resumePolling() {
        pollingEnabled = true
    }

    func handleSystemWillSleep(now: Date = Date()) {
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        sleepStartedAt = now
        runningConfigIDsBeforeSleep = configs
            .filter { runningInstance(matching: $0.config) != nil }
            .map(\.id)
        pausePolling()
    }

    func handleSystemDidWake(now: Date = Date()) async {
        let sleepDuration = sleepStartedAt.map { now.timeIntervalSince($0) } ?? 0
        let configIDsToRecover = runningConfigIDsBeforeSleep
        sleepStartedAt = nil
        runningConfigIDsBeforeSleep = []
        resumePolling()
        await refreshRuntime()

        guard sleepDuration >= Self.sleepRecoveryRestartThreshold,
              !configIDsToRecover.isEmpty
        else { return }

        await recoverPreviouslyRunningConfigsAfterWake(configIDs: configIDsToRecover)
    }

    private func registerSleepWakeNotifications() {
        unregisterSleepWakeNotifications()
        let center = NSWorkspace.shared.notificationCenter
        let willSleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWillSleep()
            }
        }
        let didWakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.wakeRecoveryTask?.cancel()
                self?.wakeRecoveryTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    await self?.handleSystemDidWake()
                }
            }
        }
        sleepWakeNotificationObservers = [willSleepObserver, didWakeObserver]
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.clearSecretCache()
            }
        }
    }

    private func unregisterSleepWakeNotifications() {
        for observer in sleepWakeNotificationObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        sleepWakeNotificationObservers = []
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
    }

    private func clearSecretCache() {
        secretCache.removeAll()
    }

    private func recoverPreviouslyRunningConfigsAfterWake(configIDs: [String]) async {
        let configsToRecover = configIDs.compactMap { id in
            configs.first { $0.id == id }?.config
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
            clearPendingStart(for: config)
        }
        if config.requiresTUN, let helperRegistration {
            do {
                try await helperRegistration.ensureRegistered()
            } catch {
                pendingStartAfterApproval = cleanConfig
                throw error
            }
        }
        try await targetClient.run(config: cleanConfig)
        instanceClientKind[cleanConfig.instance_id] = clientKind(for: cleanConfig)
        recordPendingStart(for: config)
        log("Recovered \(config.network_name) after system wake.")
    }

    private func refreshRuntimeThrowing() async throws {
        // Merge runtime info from both the privileged daemon (TUN instances) and
        // the in-process client (no_tun instances). Failures from either side
        // are tolerated so a missing/unapproved helper does not break no_tun.
        var infos: [String: NetworkInstanceRunningInfo] = [:]
        if helperRegistration?.state == .enabled {
            if let daemonInfos = try? await privilegedClient.collectNetworkInfos() {
                infos.merge(daemonInfos) { _, new in new }
            }
        }
        if let inProcessInfos = try? await inProcessClient.collectNetworkInfos() {
            infos.merge(inProcessInfos) { _, new in new }
        }

        let previousOrder = instances.map(\.name)
        let newNames = infos.keys.filter { !previousOrder.contains($0) }
        let keptNames = previousOrder.filter { infos.keys.contains($0) }
        let orderedNames = newNames + keptNames
        var running = orderedNames.compactMap { key -> NetworkInstance? in
            guard let detail = infos[key] else { return nil }
            let resolvedID = detail.instance_id ?? key
            return NetworkInstance(
                instance_id: resolvedID,
                name: key,
                running: true,
                detail: detail
            )
        }
        mergePendingStarts(into: &running)
        recordTrafficSamples(for: running)

        var newDetails: [String: NetworkInstanceRunningInfo] = [:]
        for instance in running {
            if let detail = instance.detail {
                newDetails[instance.name] = detail
            }
        }
        runtimeDetails = newDetails

        if !instancesStructureUnchanged(instances, running) {
            instances = running
        }
        updateSystemSleepAssertion(for: running)
        await reconcileRuntimeIntents()
        if mode.configServerURL == nil {
            isConfigServerConnected = false
        } else if helperRegistration?.state == .enabled {
            isConfigServerConnected = try await privilegedClient.isConfigServerClientConnected()
        } else {
            isConfigServerConnected = false
        }
    }

    private func instancesStructureUnchanged(_ current: [NetworkInstance], _ running: [NetworkInstance]) -> Bool {
        guard current.count == running.count else { return false }
        let currentByID = Dictionary(current.map { ($0.instance_id, $0) }, uniquingKeysWith: { $1 })
        for newInstance in running {
            guard let oldInstance = currentByID[newInstance.instance_id] else { return false }
            if oldInstance.name != newInstance.name { return false }
            if oldInstance.error_msg != newInstance.error_msg { return false }

            let oldMembers = oldInstance.detail?.memberStatuses ?? []
            let newMembers = newInstance.detail?.memberStatuses ?? []
            guard oldMembers.count == newMembers.count else { return false }
            for (old, new) in zip(oldMembers, newMembers) {
                if old.id != new.id { return false }
                if old.hostname != new.hostname { return false }
                if old.isLocal != new.isLocal { return false }
                if old.virtualIPv4 != new.virtualIPv4 { return false }
                if old.isPublicServer != new.isPublicServer { return false }
                if old.peerID != new.peerID { return false }
                if old.instanceID != new.instanceID { return false }
            }
        }
        return true
    }

    private func reconcileRuntimeIntents() async {
        let ids = runtimeIntents
            .filter { $0.kind == .hostname }
            .map(\.id)
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
            save()
        }
    }

    private func reconcileHostnameIntent(id: String, force: Bool = false) async {
        guard let intent = runtimeIntents.first(where: { $0.id == id }),
              intent.kind == .hostname,
              let desiredHostname = nonEmptyTrimmed(intent.desired.hostname)
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

        let baseHostname = nonEmptyTrimmed(intent.base.hostname)
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
                rpcURL: nil,
                label: instance.name,
                isLocal: true
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
                label: member.hostname,
                isLocal: false
            )
        }

        return nil
    }

    private func applyHostname(_ hostname: String, to observation: RuntimeIntentObservation) async throws {
        guard observation.isLocal || observation.rpcURL != nil else {
            throw EasyTierCoreError.invalidResponse("remote runtime RPC URL is missing")
        }
        guard !observation.instanceID.isEmpty else {
            throw EasyTierCoreError.invalidResponse("runtime RPC target is missing")
        }
        let transport = EasyTierCoreRPCTransport(client: privilegedClient, rpcURL: observation.rpcURL)
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
        save()
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
        let storedHostname = nonEmptyTrimmed(configs[index].config.hostname)
        guard storedHostname != runtimeHostname else { return }

        configs[index].config.hostname = runtimeHostname
        if selectedConfigID == configID {
            selectedConfigID = configs[index].id
        }
        save()
    }

    private func snapshotForStorage() throws -> AppSnapshot {
        AppSnapshot(
            configs: try configsWithSecretsStored(configs),
            mode: mode,
            lastSelectedConfigID: selectedConfigID,
            vpnOnDemandEnabled: vpnOnDemandEnabled,
            runtimeIntents: runtimeIntents,
            reversedPortForwardFingerprints: reversedPortForwardFingerprints
        )
    }

    private func configsWithSecretsStored(_ storedConfigs: [StoredNetworkConfig]) throws -> [StoredNetworkConfig] {
        var storedConfigs = storedConfigs
        for index in storedConfigs.indices {
            guard let secret = storedConfigs[index].config.network_secret?.nilIfEmpty else { continue }
            try networkSecretStore.save(secret, for: storedConfigs[index].config)
            secretCache[storedConfigs[index].config.network_name] = secret
            storedConfigs[index].config.network_secret = nil
        }
        return storedConfigs
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

    private func nonEmptyTrimmed(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func uniquelyMatchedInstance(named networkName: String) -> NetworkInstance? {
        let matchingConfigs = configs.filter { $0.config.network_name == networkName }
        guard matchingConfigs.count <= 1 else { return nil }

        let matches = instances.filter { instance in
            instance.name == networkName || instance.instance_id == networkName
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func uniquelyMatchedConfig(named networkName: String) -> NetworkConfig? {
        let matches = configs.filter { $0.config.network_name == networkName }
        return matches.count == 1 ? matches[0].config : nil
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

    private func recordPendingStart(for config: NetworkConfig) {
        pendingStarts[config.instance_id] = PendingNetworkStart(
            instanceID: config.instance_id,
            name: config.network_name
        )
    }

    private func clearPendingStart(for config: NetworkConfig) {
        pendingStarts.removeValue(forKey: config.instance_id)
    }

    private func mergePendingStarts(into running: inout [NetworkInstance]) {
        let runningIDs = Set(running.map(\.instance_id))
        let runningNames = Set(running.map(\.name))

        pendingStarts = pendingStarts.filter { _, pending in
            if runningIDs.contains(pending.instanceID) || runningNames.contains(pending.name) {
                return false
            }
            return true
        }

        for pending in pendingStarts.values.sorted(by: { $0.name < $1.name }) {
            guard !running.contains(where: { $0.instance_id == pending.instanceID || $0.name == pending.name }) else { continue }
            running.append(
                NetworkInstance(
                    instance_id: pending.instanceID,
                    name: pending.name,
                    running: true,
                    detail: NetworkInstanceRunningInfo(running: true)
                )
            )
        }
    }

    private func recordTrafficSamples(for instances: [NetworkInstance]) {
        let now = Date()
        let activeNames = Set(instances.map(\.name))
        trafficSamplesByInstance = trafficSamplesByInstance.filter { activeNames.contains($0.key) }
        lastTrafficCounters = lastTrafficCounters.filter { activeNames.contains($0.key) }

        for instance in instances {
            guard let detail = instance.detail else { continue }
            let totals = detail.trafficTotals
            let previous = lastTrafficCounters[instance.name]
            lastTrafficCounters[instance.name] = (now, totals.txBytes, totals.rxBytes)

            guard let previous else {
                appendTrafficSample(TrafficSample(timestamp: now, txBytesPerSecond: 0, rxBytesPerSecond: 0), for: instance.name)
                continue
            }

            let interval = max(now.timeIntervalSince(previous.timestamp), 0.001)
            let txDelta = max(0, totals.txBytes - previous.txBytes)
            let rxDelta = max(0, totals.rxBytes - previous.rxBytes)
            appendTrafficSample(
                TrafficSample(
                    timestamp: now,
                    txBytesPerSecond: Double(txDelta) / interval,
                    rxBytesPerSecond: Double(rxDelta) / interval
                ),
                for: instance.name
            )
        }
    }

    private func appendTrafficSample(_ sample: TrafficSample, for instanceName: String) {
        var samples = trafficSamplesByInstance[instanceName] ?? []
        samples.append(sample)
        if samples.count > Self.trafficSampleWindow {
            samples.removeFirst(samples.count - Self.trafficSampleWindow)
        }
        trafficSamplesByInstance[instanceName] = samples
    }

    private func updateSystemSleepAssertion(for running: [NetworkInstance]) {
        systemSleepPreventer.setSystemSleepPrevented(
            !running.isEmpty,
            reason: "EasyTier is keeping network instances reachable."
        )
    }

    private func busy(_ operation: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            // Surface the error to the UI instead of suppressing helper-permission messages.
            setLastError(error)
            log("Error: \(error.localizedDescription)")
        }
    }

    private func setLastError(_ error: Error) {
        setLastError(error.localizedDescription, kind: Self.lastErrorKind(for: error))
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

    private func uniqueNetworkName() -> String {
        let base = "easytier"
        let existing = Set(configs.map { $0.config.network_name })
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
    private static let trafficSampleWindow = 60
    private static let sleepRecoveryRestartThreshold: TimeInterval = 30
}

public struct LogEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

private struct PendingNetworkStart: Sendable {
    var instanceID: String
    var name: String
}

private struct RuntimeIntentObservation {
    var instanceID: String
    var hostname: String?
    var ipv4: String?
    var rpcURL: URL?
    var label: String
    var isLocal: Bool
}
