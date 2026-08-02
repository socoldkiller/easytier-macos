import Foundation
import Observation
import TOML

extension EasyTierAppStore {
    public func startPolling() {
        runtimeSession.startPolling(
            refresh: { [weak self] in await self?.refreshRuntime() },
            handleWillSleep: { [weak self] in self?.handleSystemWillSleep() },
            handleSessionResign: { [weak self] in self?.handleUserSessionDidResignActive() },
            handleDidWake: { [weak self] in await self?.handleSystemDidWake() },
            pollingIntervalProvider: { [weak self] in
                guard let self else { return .seconds(1) }
                return self.usesReducedPollingInterval ? .seconds(5) : .seconds(1)
            }
        )
    }

    /// While the app is idle (no runtime instances, no scroll gesture, not on
    /// the traffic tab, and no in-flight transition), polling can slow down to
    /// reduce background work. Any of those conditions forces the regular
    /// one-second cadence.
    private var usesReducedPollingInterval: Bool {
        instances.isEmpty
            && !isAnyViewScrolling
            && selectedTab != .view
            && runtimeTransitionsByConfigID.isEmpty
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

    func recoverPreviouslyRunningConfigsAfterWake(
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

    func recoverConfigAfterWake(_ config: NetworkConfig) async throws {
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

    func refreshRuntimeThrowing(allowDuringRuntimeMutation: Bool = false) async throws {
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
        await refreshRuntimeManagedConfigurations()
        // A mutation's authoritative collect must not hold the control-plane
        // FIFO while hostname intent RPCs are retried. Normal polling performs
        // that reconciliation on the next refresh.
        if !allowDuringRuntimeMutation {
            await reconcileRuntimeIntents()
        }
    }

    public func reloadSelectedRuntimeManagedConfiguration() async {
        guard let selectedConfigID, selectedConfigIsRuntimeManaged else { return }
        runtimeManagedConfigDetails.removeValue(forKey: selectedConfigID)
        runtimeManagedConfigLoadErrors.removeValue(forKey: selectedConfigID)
        await refreshRuntimeManagedConfigurations()
    }

    private func refreshRuntimeManagedConfigurations() async {
        let managedInstances = instances.filter { localConfig(matching: $0) == nil }
        let managedIDs = Set(managedInstances.map(\.instance_id))
        var loaded = runtimeManagedConfigDetails.filter { managedIDs.contains($0.key) }
        var errors = runtimeManagedConfigLoadErrors.filter { managedIDs.contains($0.key) }

        guard !managedInstances.isEmpty else {
            runtimeManagedConfigDetails = [:]
            runtimeManagedConfigLoadErrors = [:]
            return
        }

        guard let rpcURL = mode.localRPCURL else {
            for instance in managedInstances where loaded[instance.instance_id] == nil {
                errors[instance.instance_id] =
                    "Local RPC is disabled. Enable RPC Listen to read this Config Server-managed configuration."
            }
            runtimeManagedConfigDetails = loaded
            runtimeManagedConfigLoadErrors = errors
            return
        }

        let rpcClient = EasyTierRemoteRPCClient(rpcURL: rpcURL, client: runtimeClient)
        for instance in managedInstances where loaded[instance.instance_id] == nil {
            do {
                var config = try await rpcClient.getConfigParsed(instanceID: instance.instance_id)
                config.instance_id = instance.instance_id
                if config.network_name.isEmpty {
                    config.network_name = instance.name
                }
                loaded[instance.instance_id] = Self.configWithoutNetworkSecret(config)
                errors.removeValue(forKey: instance.instance_id)
            } catch {
                errors[instance.instance_id] = error.localizedDescription
            }
        }

        let currentManagedIDs = Set(
            instances.lazy
                .filter { self.localConfig(matching: $0) == nil }
                .map(\.instance_id)
        )
        runtimeManagedConfigDetails = loaded.filter { currentManagedIDs.contains($0.key) }
        runtimeManagedConfigLoadErrors = errors.filter { currentManagedIDs.contains($0.key) }
    }

    func reconcileRuntimeIntents() async {
        let ids = runtimeIntents.map(\.id)
        for id in ids {
            await reconcileHostnameIntent(id: id)
        }
        await cleanupExpiredIntents()
    }

    func cleanupExpiredIntents() async {
        do {
            var state = try stateForStorage()
            guard RuntimeIntentReconciler.removeExpired(from: &state.runtimeIntents) else { return }
            try await commitPersistenceState(state)
        } catch {
            setLastError(error)
            log("Could not remove expired runtime intents: \(error.localizedDescription)")
        }
    }

    func reconcileHostnameIntent(id: String, force: Bool = false) async {
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

    func runtimeObservation(for target: RuntimeIntentTarget) -> RuntimeIntentObservation? {
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

    func applyHostname(_ hostname: String, to observation: RuntimeIntentObservation) async throws {
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

    func updateRuntimeIntent(
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

    func setRuntimeIntentStatus(_ id: String, _ status: RuntimeIntentStatus) async {
        await updateRuntimeIntent(id: id) { intent in
            intent.status = status
            intent.updatedAt = Date()
        }
    }

    func persistRuntimeHostname(from instance: NetworkInstance, forConfigID configID: String) async throws {
        guard let runtimeHostname = instance.detail?.my_node_info?.hostname?.trimmedNilIfEmpty else { return }
        var state = try stateForStorage()
        guard let index = state.configs.firstIndex(where: { $0.id == configID }) else { return }
        let storedHostname = state.configs[index].hostname?.trimmedNilIfEmpty
        guard storedHostname != runtimeHostname else { return }

        state.configs[index].hostname = runtimeHostname
        try await commitPersistenceState(state)
    }

}
