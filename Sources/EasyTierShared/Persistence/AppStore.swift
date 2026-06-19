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
    public var isShowingAbout = false
    public var isShowingLinuxInstallGuide = false
    public var isConfigServerConnected = false
    public var trafficSamplesByInstance: [String: [TrafficSample]] = [:]

    private let client: any EasyTierCoreClient
    private let storage: EasyTierStorage
    private var pollingTask: Task<Void, Never>?
    private var lastTrafficCounters: [String: (timestamp: Date, txBytes: Int64, rxBytes: Int64)] = [:]
    private var pendingStarts: [String: PendingNetworkStart] = [:]

    public init(client: any EasyTierCoreClient = PrivilegedEasyTierClient(), storage: EasyTierStorage = .default) {
        self.client = client
        self.storage = storage
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
            configs = snapshot.configs.isEmpty ? [StoredNetworkConfig(config: NetworkConfig())] : snapshot.configs
            let loadedMode = snapshot.mode ?? .default
            if case .service = loadedMode {
                mode = .default
                log("Service mode is not available in this build; switched to Normal mode.")
            } else {
                mode = loadedMode
            }
            if let lastSelectedConfigID = snapshot.lastSelectedConfigID,
               configs.contains(where: { $0.id == lastSelectedConfigID })
            {
                selectedConfigID = lastSelectedConfigID
            } else {
                selectedConfigID = configs.first?.id
            }
            log("Loaded \(configs.count) saved network config(s).")
        } catch {
            configs = [StoredNetworkConfig(config: NetworkConfig())]
            selectedConfigID = configs.first?.id
            lastError = error.localizedDescription
            log("Failed to load state: \(error.localizedDescription)")
        }
        startPolling()
    }

    public func save() {
        do {
            try storage.save(AppSnapshot(
                configs: configs,
                mode: mode,
                lastSelectedConfigID: selectedConfigID
            ))
            log("Saved app state.")
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
        save()
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
        configs.remove(at: index)
        if configs.isEmpty { configs.append(StoredNetworkConfig(config: NetworkConfig())) }
        self.selectedConfigID = configs.first?.id
        save()
        await refreshRuntime()
    }

    public func updateSelectedConfig(_ config: NetworkConfig) {
        guard let selectedConfigID else { return }
        updateConfig(id: selectedConfigID, with: config, saveImmediately: true)
    }

    public func updateConfig(id: String, with config: NetworkConfig, saveImmediately: Bool = false) {
        guard let index = configs.firstIndex(where: { $0.id == id }) else { return }
        configs[index].config = config
        if selectedConfigID == id {
            selectedConfigID = configs[index].id
        }
        if saveImmediately {
            save()
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
            try await client.validate(toml: try NetworkConfigTOMLCodec.encode(config))
            log("Validated \(config.network_name).")
        }
    }

    public func runSelectedConfig() async {
        guard let config = selectedConfig else { return }
        await busy {
            log("Starting \(config.network_name)...")
            try validateConfigForCurrentRuntime(config)
            try await client.run(config: config)
            recordPendingStart(for: config)
            log("Started \(config.network_name).")
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
            try await client.validate(toml: try NetworkConfigTOMLCodec.encode(config))
            try await client.stop(instanceNames: [instance.name])
            clearPendingStart(for: config)
            try await client.run(config: config)
            recordPendingStart(for: config)
            log("Restarted \(config.network_name).")
            try await refreshRuntimeThrowing()
        }
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

    public func refreshRuntime() async {
        do {
            try await refreshRuntimeThrowing()
        } catch {
            guard !handleHelperPermissionError(error) else { return }
            lastError = error.localizedDescription
        }
    }

    public func clearHelperPermissionError() {
        if isHelperPermissionErrorMessage(lastError) {
            lastError = nil
        }
    }

    public func easyTierCoreVersion() async throws -> String {
        try await client.version()
    }

    public func applyMode(_ mode: AppMode) async {
        let effectiveMode: AppMode
        if case .service = mode {
            effectiveMode = .default
            log("Service mode is not available in this build; switched to Normal mode.")
        } else {
            effectiveMode = mode
        }

        self.mode = effectiveMode
        save()
        if let url = effectiveMode.configServerURL {
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
        return try NetworkConfigTOMLCodec.encode(selectedConfig)
    }

    public func importTOML(_ toml: String) {
        do {
            let config = try NetworkConfigTOMLCodec.decode(toml)
            configs.append(StoredNetworkConfig(config: config))
            selectedConfigID = config.instance_id
            selectedTab = .config
            save()
            log("Imported \(config.network_name).")
        } catch {
            lastError = error.localizedDescription
            log("Import failed: \(error.localizedDescription)")
        }
    }

    public func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.refreshRuntime()
            }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func refreshRuntimeThrowing() async throws {
        var running = try await client.listInstances()
        let infos = try await client.collectNetworkInfos()
        for index in running.indices {
            if let detail = runtimeInfo(for: running[index], in: infos) {
                running[index].detail = detail
            } else {
                running[index].detail = NetworkInstanceRunningInfo(
                    running: true,
                    error_msg: "Runtime detail is missing for \(running[index].name). EasyTier may still be starting, or the privileged helper is older than the GUI."
                )
            }
            running[index].running = true
        }
        mergePendingStarts(into: &running)
        recordTrafficSamples(for: running)
        instances = running
        if mode.configServerURL == nil {
            isConfigServerConnected = false
        } else {
            isConfigServerConnected = try await client.isConfigServerClientConnected()
        }
    }

    private func runtimeInfo(for instance: NetworkInstance, in infos: [String: NetworkInstanceRunningInfo]) -> NetworkInstanceRunningInfo? {
        if let byID = infos[instance.instance_id] { return byID }
        if let byName = infos[instance.name] { return byName }
        return nil
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
        return isHelperPermissionErrorMessage(error.localizedDescription)
    }

    private static func isHelperPermissionErrorMessage(_ message: String?) -> Bool {
        guard let message else { return false }
        return helperPermissionErrorCodes.contains { message.contains($0) }
            || message.contains("macOS has not allowed")
            || message.contains("Click Install Helper")
            || message.contains("privileged helper is not installed")
    }

    private func isHelperPermissionErrorMessage(_ message: String?) -> Bool {
        Self.isHelperPermissionErrorMessage(message)
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
