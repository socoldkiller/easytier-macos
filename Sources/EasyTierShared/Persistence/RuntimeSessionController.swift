import AppKit
import Foundation

@MainActor
final class RuntimeSessionController {
    enum ClientKind: Sendable {
        case inProcess
        case privileged
    }

    private let privilegedClient: any EasyTierCoreClient
    private let inProcessClient: any EasyTierCoreClient
    private let helperRegistration: HelperRegistrationService?
    private let systemSleepPreventer: any SystemSleepPreventing

    private var pollingTask: Task<Void, Never>?
    private var trafficCountersByInstance: [String: RuntimeTrafficCounter] = [:]
    private var pendingStarts: [String: PendingNetworkStart] = [:]
    private var pollingEnabled = true
    private var instanceClientKind: [String: ClientKind] = [:]
    private var pendingStartAfterApproval: NetworkConfig?
    private var sleepStartedAt: Date?
    private var runningConfigIDsBeforeSleep: [String] = []
    private var runtimeOperationGenerationBeforeSleep: UInt64?
    private var notificationTasks: [Task<Void, Never>] = []
    private var wakeRecoveryTask: Task<Void, Never>?

    init(
        privilegedClient: any EasyTierCoreClient,
        inProcessClient: any EasyTierCoreClient,
        helperRegistration: HelperRegistrationService?,
        systemSleepPreventer: any SystemSleepPreventing
    ) {
        self.privilegedClient = privilegedClient
        self.inProcessClient = inProcessClient
        self.helperRegistration = helperRegistration
        self.systemSleepPreventer = systemSleepPreventer
    }

    func client(for config: NetworkConfig) -> any EasyTierCoreClient {
        config.requiresTUN ? privilegedClient : inProcessClient
    }

    func clientKind(for config: NetworkConfig) -> ClientKind {
        config.requiresTUN ? .privileged : .inProcess
    }

    func setClientKind(for config: NetworkConfig) {
        instanceClientKind[config.instance_id] = clientKind(for: config)
    }

    func clearClientKind(for config: NetworkConfig) {
        instanceClientKind.removeValue(forKey: config.instance_id)
        trafficCountersByInstance.removeValue(forKey: config.network_name)
    }

    func clearTrafficTracking(instanceName: String) {
        trafficCountersByInstance.removeValue(forKey: instanceName)
    }

    func hasPrivilegedInstances(in instances: [NetworkInstance]) -> Bool {
        instances.contains { instanceClientKind[$0.instance_id] != .inProcess }
    }

    func inProcessInstanceNames(in instances: [NetworkInstance]) -> [String] {
        instances
            .filter { instanceClientKind[$0.instance_id] == .inProcess }
            .map(\.name)
    }

    func clearRuntimeTracking() {
        instanceClientKind.removeAll()
        pendingStarts.removeAll()
        trafficCountersByInstance.removeAll()
    }

    func setPendingStartAfterApproval(_ config: NetworkConfig) {
        pendingStartAfterApproval = config
    }

    func restorePendingStartAfterApprovalIfEmpty(_ config: NetworkConfig) {
        guard pendingStartAfterApproval == nil else { return }
        pendingStartAfterApproval = config
    }

    func takePendingStartAfterApproval() -> NetworkConfig? {
        defer { pendingStartAfterApproval = nil }
        return pendingStartAfterApproval
    }

    func recordPendingStart(for config: NetworkConfig) {
        pendingStarts[config.instance_id] = PendingNetworkStart(
            instanceID: config.instance_id,
            name: config.network_name,
            requiresTUN: config.requiresTUN
        )
    }

    func clearPendingStart(for config: NetworkConfig) {
        pendingStarts.removeValue(forKey: config.instance_id)
    }

    func refreshRuntime(
        currentInstances: [NetworkInstance],
        currentRuntimeDetails: [String: NetworkInstanceRunningInfo],
        currentStatusMetrics: [String: [String: RuntimeMemberStatusMetricsSnapshot]],
        currentTrafficSamples: [String: [TrafficSample]],
        currentTrafficSamplingStatus: [String: RuntimeTrafficSamplingStatus],
        selectedTab: WorkspaceTab,
        shouldApply: @escaping @MainActor () -> Bool = { true }
    ) async throws -> RuntimePresentationChange? {
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

        guard shouldApply() else { return nil }

        let previousOrder = currentInstances.map(\.name)
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

        let presentationChange = RuntimePresentationReducer.reduce(
            running: running,
            previous: RuntimePresentationState(
                instances: currentInstances,
                runtimeDetails: currentRuntimeDetails,
                statusMetricsByInstance: currentStatusMetrics,
                trafficSamplesByInstance: currentTrafficSamples,
                trafficCountersByInstance: trafficCountersByInstance,
                trafficSamplingStatusByInstance: currentTrafficSamplingStatus
            ),
            selectedTab: selectedTab
        )
        trafficCountersByInstance = presentationChange.state.trafficCountersByInstance
        updateSystemSleepAssertion(for: running)

        return presentationChange
    }

    func startPolling(
        refresh: @escaping @MainActor () async -> Void,
        clearSecretCache: @escaping @MainActor () -> Void,
        handleWillSleep: @escaping @MainActor () -> Void,
        handleDidWake: @escaping @MainActor () async -> Void
    ) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.pollingEnabled else { continue }
                await refresh()
            }
        }
        registerSleepWakeNotifications(
            clearSecretCache: clearSecretCache,
            handleWillSleep: handleWillSleep,
            handleDidWake: handleDidWake
        )
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        updateSystemSleepAssertion(for: [])
        unregisterSleepWakeNotifications()
    }

    func pausePolling() {
        pollingEnabled = false
    }

    func resumePolling() {
        pollingEnabled = true
    }

    func handleSystemWillSleep(
        now: Date = Date(),
        recoverableConfigIDs: [String],
        operationGeneration: UInt64?
    ) {
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        sleepStartedAt = now
        runningConfigIDsBeforeSleep = operationGeneration == nil ? [] : recoverableConfigIDs
        runtimeOperationGenerationBeforeSleep = operationGeneration
        pausePolling()
    }

    func wakeRecoveryRequest(
        now: Date = Date()
    ) -> (configIDs: [String], expectedOperationGeneration: UInt64)? {
        let sleepDuration = sleepStartedAt.map { now.timeIntervalSince($0) } ?? 0
        let configIDsToRecover = runningConfigIDsBeforeSleep
        let expectedOperationGeneration = runtimeOperationGenerationBeforeSleep
        sleepStartedAt = nil
        runningConfigIDsBeforeSleep = []
        runtimeOperationGenerationBeforeSleep = nil
        resumePolling()

        guard sleepDuration >= Self.sleepRecoveryRestartThreshold,
              !configIDsToRecover.isEmpty,
              let expectedOperationGeneration
        else { return nil }
        return (configIDsToRecover, expectedOperationGeneration)
    }

    private func registerSleepWakeNotifications(
        clearSecretCache: @escaping @MainActor () -> Void,
        handleWillSleep: @escaping @MainActor () -> Void,
        handleDidWake: @escaping @MainActor () async -> Void
    ) {
        unregisterSleepWakeNotifications()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationTasks = [
            Task { @MainActor in
                let notifications = workspaceCenter.notifications(named: NSWorkspace.willSleepNotification)
                for await _ in notifications {
                    guard !Task.isCancelled else { break }
                    handleWillSleep()
                }
            },
            Task { @MainActor [weak self] in
                let notifications = workspaceCenter.notifications(named: NSWorkspace.didWakeNotification)
                for await _ in notifications {
                    guard !Task.isCancelled else { break }
                    self?.scheduleWakeRecovery(handleDidWake: handleDidWake)
                }
            },
            Task { @MainActor in
                let notifications = NotificationCenter.default.notifications(named: NSApplication.didResignActiveNotification)
                for await _ in notifications {
                    guard !Task.isCancelled else { break }
                    clearSecretCache()
                }
            },
        ]
    }

    private func scheduleWakeRecovery(handleDidWake: @escaping @MainActor () async -> Void) {
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await handleDidWake()
        }
    }

    private func unregisterSleepWakeNotifications() {
        for task in notificationTasks {
            task.cancel()
        }
        notificationTasks = []
    }

    private func mergePendingStarts(into running: inout [NetworkInstance]) {
        pendingStarts = pendingStarts.filter { _, pending in
            guard let instance = running.first(where: {
                $0.instance_id == pending.instanceID || $0.name == pending.name
            }) else { return true }

            let phase = instance.runtimeReadinessPhase(requiresTUN: pending.requiresTUN)
            return phase == .starting || phase == .stopped
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

    private func updateSystemSleepAssertion(for running: [NetworkInstance]) {
        systemSleepPreventer.setSystemSleepPrevented(
            !running.isEmpty,
            reason: "EasyTier is keeping network instances reachable."
        )
    }

    private static let sleepRecoveryRestartThreshold: TimeInterval = 30
}

private struct PendingNetworkStart: Sendable {
    var instanceID: String
    var name: String
    var requiresTUN: Bool
}
