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
    public var selectedTab: WorkspaceTab = .status
    public var logLines: [String] = []
    public var isBusy = false
    public var lastError: String?
    public var isShowingSettings = false
    public var isShowingAbout = false
    public var isShowingLinuxInstallGuide = false
    public var isConfigServerConnected = false
    public var trafficSamplesByInstance: [String: [TrafficSample]] = [:]
    public var runtimeIntents: [RuntimeIntent] = []
    public var reversedPortForwardFingerprints: [String: Set<String>] = [:]

    public static func portForwardFingerprint(for rule: PortForwardConfig) -> String {
        "\(rule.bind_ip):\(rule.bind_port)-\(rule.dst_ip):\(rule.dst_port)-\(rule.proto)"
    }

    private let client: any EasyTierCoreClient
    private let storage: EasyTierStorage
    private let networkSecretStore: any NetworkSecretStore
    private var pollingTask: Task<Void, Never>?
    private var lastTrafficCounters: [String: (timestamp: Date, txBytes: Int64, rxBytes: Int64)] = [:]
    private var pendingStarts: [String: PendingNetworkStart] = [:]
    private var pollingEnabled: Bool = true

    public init(
        client: any EasyTierCoreClient = PrivilegedEasyTierClient(),
        storage: EasyTierStorage = .default,
        networkSecretStore: any NetworkSecretStore = SystemNetworkSecretStore()
    ) {
        self.client = client
        self.storage = storage
        self.networkSecretStore = networkSecretStore
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

    public var selectedMemberStatuses: [NetworkMemberStatus] {
        selectedRunningInstance?.detail?.memberStatuses ?? []
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
            lastError = error.localizedDescription
            log("Failed to load state: \(error.localizedDescription)")
        }
        await refreshRuntime()
        startPolling()
    }

    public func save() {
        do {
            let snapshot = try snapshotForStorage()
            try storage.save(snapshot)
            configs = snapshot.configs
        } catch {
            lastError = error.localizedDescription
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

    private func saveInBackground() {
        let snapshot: AppSnapshot
        do {
            snapshot = try snapshotForStorage()
            configs = snapshot.configs
        } catch {
            lastError = error.localizedDescription
            log("Save failed: \(error.localizedDescription)")
            return
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
                try await client.stop(instanceNames: [runningInstance.name])
            } catch {
                lastError = error.localizedDescription
                log("Delete canceled because \(config.network_name) could not be stopped: \(error.localizedDescription)")
                return
            }
        }
        clearPendingStart(for: config)
        runtimeIntents.removeAll { intent in
            intent.target.isLocal && (intent.target.instanceID == config.instance_id || intent.target.networkName == config.network_name)
        }
        reversedPortForwardFingerprints.removeValue(forKey: config.instance_id)
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
        if selectedConfigID == id {
            selectedConfigID = configs[index].id
        }
        if saveImmediately {
            save()
        }
    }

    private func migrateNetworkSecret(from oldConfig: NetworkConfig, to newConfig: NetworkConfig) {
        do {
            guard let secret = try networkSecretStore.secret(for: oldConfig, reason: nil) else { return }
            try networkSecretStore.save(secret, for: newConfig)
            try networkSecretStore.deleteSecret(for: oldConfig)
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
            let keychainConfig = try configWithKeychainSecret(config, reason: "Use the network secret for validation.")
            try await client.validate(toml: try NetworkConfigTOMLCodec.encode(keychainConfig))
            log("Validated \(config.network_name).")
        }
    }

    public func runSelectedConfig() async {
        guard let config = selectedConfig else { return }
        await busy {
            log("Starting \(config.network_name)...")
            try validateConfigForCurrentRuntime(config)
            let keychainConfig = try configWithKeychainSecret(config, reason: "Use the network secret to start \(config.network_name).")
            let cleanConfig = Self.configWithoutReversedPortForwards(keychainConfig, fingerprints: reversedPortForwardFingerprints)
            try await client.run(config: cleanConfig)
            recordPendingStart(for: config)
            log("Started \(config.network_name).")
            try await refreshRuntimeThrowing()
            if let error = selectedRunningInstance?.runtimeErrorMessage ?? selectedRunningInstance?.listenerErrorFromEvents {
                lastError = error
            }
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
            try await client.stop(instanceNames: [runningInstance.name])
            clearPendingStart(for: config)
            log("Stopped \(config.network_name).")
            try await refreshRuntimeThrowing()
        }
    }

    public func restartSelectedConfig(replacing instance: NetworkInstance) async {
        guard let config = selectedConfig else { return }
        await busy {
            log("Restarting \(config.network_name)...")
            try validateConfigForCurrentRuntime(config, replacing: instance)
            let keychainConfig = try configWithKeychainSecret(config, reason: "Use the network secret to restart \(config.network_name).")
            let cleanConfig = Self.configWithoutReversedPortForwards(keychainConfig, fingerprints: reversedPortForwardFingerprints)
            try await client.validate(toml: try NetworkConfigTOMLCodec.encode(cleanConfig))
            try await client.stop(instanceNames: [instance.name])
            clearPendingStart(for: config)
            try await client.run(config: cleanConfig)
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
            try await client.retain(instanceNames: [])
            pendingStarts.removeAll()
            log("Stopped all EasyTier instances.")
            try await refreshRuntimeThrowing()
        }
    }

    public func clearLogs() {
        logLines.removeAll()
    }

    public func refreshRuntime() async {
        do {
            try await refreshRuntimeThrowing()
        } catch {
            guard !handleHelperPermissionError(error) else { return }
            lastError = error.localizedDescription
        }
    }

    public func recordNotice(_ message: String) {
        log(message)
    }

    public func clearHelperPermissionError() {
        if Self.isHelperPermissionErrorMessage(lastError) {
            lastError = nil
        }
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
        try await client.version()
    }

    public func applyMode(_ mode: AppMode) async {
        self.mode = mode
        save()

        await busy {
            try await client.configureRPCPortal(mode.rpcPortal, whitelist: mode.rpcPortalWhitelist)
            if let rpcPortal = mode.rpcPortal {
                log("RPC portal listening: \(rpcPortal)")
            } else {
                log("RPC portal disabled.")
            }
        }

        if let url = mode.configServerURL {
            await busy {
                try await client.startConfigServerClient(url: url)
                isConfigServerConnected = try await client.isConfigServerClientConnected()
                log("Config server client started: \(url.absoluteString)")
            }
        } else {
            do {
                try await client.stopConfigServerClient()
                isConfigServerConnected = false
            } catch {
                log("Config server stop failed: \(error.localizedDescription)")
            }
        }
    }

    public func exportSelectedTOML() throws -> String {
        guard let selectedConfig else { return "" }
        let config = try configWithKeychainSecret(selectedConfig, reason: "Use the network secret for TOML export.")
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
            lastError = error.localizedDescription
            log("Import failed: \(error.localizedDescription)")
        }
    }

    public func networkSecretIsSaved(for config: NetworkConfig) -> Bool {
        networkSecretStore.containsSecret(for: config)
    }

    public func networkSecretCanAutofill(for config: NetworkConfig) -> Bool {
        networkSecretStore.containsSecret(for: config) && networkSecretStore.canAutofillWithBiometrics()
    }

    public func autofillNetworkSecret(for config: NetworkConfig) -> String? {
        try? configWithKeychainSecret(config, reason: "Use Touch ID to fill the network secret for \(config.network_name).").network_secret?.nilIfEmpty
    }

    public func revealNetworkSecret(for config: NetworkConfig) throws -> String? {
        try configWithKeychainSecret(config, reason: "Show the network secret for \(config.network_name).").network_secret?.nilIfEmpty
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
        unregisterSleepWakeNotifications()
    }

    public func pausePolling() {
        pollingEnabled = false
    }

    public func resumePolling() {
        pollingEnabled = true
    }

    private func registerSleepWakeNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pausePolling()
            }
        }
        center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.resumePolling()
            }
        }
    }

    private func unregisterSleepWakeNotifications() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func refreshRuntimeThrowing() async throws {
        let infos = try await client.collectNetworkInfos()
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
        if running != instances {
            instances = running
        }
        await reconcileRuntimeIntents()
        if mode.configServerURL == nil {
            isConfigServerConnected = false
        } else {
            isConfigServerConnected = try await client.isConfigServerClientConnected()
        }
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
            return RuntimeIntentObservation(
                instanceID: instance.instance_id,
                hostname: instance.detail?.my_node_info?.hostname,
                ipv4: instance.detail?.my_node_info?.displayIPv4,
                rpcURL: nil,
                label: instance.name,
                isLocal: true
            )
        }

        let candidateInstances = instances.filter { instance in
            instance.name == target.networkName || config(matching: instance)?.network_name == target.networkName
        }
        for instance in candidateInstances {
            guard let member = instance.detail?.memberStatuses.first(where: { member in
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
        let transport = EasyTierCoreRPCTransport(client: client, rpcURL: observation.rpcURL)
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
            runtimeIntents: runtimeIntents,
            reversedPortForwardFingerprints: reversedPortForwardFingerprints
        )
    }

    private func configsWithSecretsStored(_ storedConfigs: [StoredNetworkConfig]) throws -> [StoredNetworkConfig] {
        var storedConfigs = storedConfigs
        for index in storedConfigs.indices {
            guard let secret = storedConfigs[index].config.network_secret?.nilIfEmpty else { continue }
            try networkSecretStore.save(secret, for: storedConfigs[index].config)
            storedConfigs[index].config.network_secret = nil
        }
        return storedConfigs
    }

    private func configWithKeychainSecret(_ config: NetworkConfig, reason: String) throws -> NetworkConfig {
        guard config.network_secret?.nilIfEmpty == nil else { return config }
        guard let secret = try networkSecretStore.secret(for: config, reason: reason) else { return config }
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
        if samples.count > 120 {
            samples.removeFirst(samples.count - 120)
        }
        trafficSamplesByInstance[instanceName] = samples
    }

    private func busy(_ operation: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            guard !handleHelperPermissionError(error) else { return }
            lastError = error.localizedDescription
            log("Error: \(error.localizedDescription)")
        }
    }

    private func handleHelperPermissionError(_ error: Error) -> Bool {
        guard Self.isHelperPermissionError(error) else { return false }
        lastError = nil
        log("Privileged helper needs user approval before TUN networking can start.")
        return true
    }

    private static func isHelperPermissionError(_ error: Error) -> Bool {
        if let helperError = error as? PrivilegedHelperError {
            switch helperError {
            case let .helperReported(payload):
                return Self.helperPermissionErrorCodes.contains(payload.code)
            case .unavailable:
                return true
            case .invalidPayload:
                return false
            }
        }
        return Self.isHelperPermissionErrorMessage(error.localizedDescription)
    }

    private static func isHelperPermissionErrorMessage(_ message: String?) -> Bool {
        guard let message else { return false }
        return helperPermissionErrorCodes.contains { message.contains($0) }
            || message.contains("macOS has not allowed")
            || message.contains("Click Install Helper")
            || message.contains("privileged helper is not installed")
    }

    private func log(_ message: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        logLines.insert("[\(timestamp)] \(message)", at: 0)
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
    private static let helperPermissionErrorCodes: Set<String> = [
        "helperNotRegistered",
        "helperRequiresApproval",
        "helperNotFound",
    ]
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
