import Foundation
import Observation
import TOML

extension EasyTierAppStore {
    public func addConfig() async {
        guard allowsLocalConfigurationMutation else {
            recordNotice("Config Server manages this workspace. Log out before creating a local network.")
            return
        }
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
        guard allowsLocalConfigurationMutation else { return }
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
                intent.target.isLocal
                    && (intent.target.instanceID == config.instance_id
                        || intent.target.networkName == config.network_name)
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
        guard allowsLocalConfigurationMutation else { return }
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
        if isConfigServerManaged {
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
        guard allowsLocalConfigurationMutation, !selectedConfigIsRuntimeManaged else { return .none }
        var outcome = NetworkSecretOperationOutcome.none
        await withRuntimeMutation {
            outcome = await runSelectedConfigWithoutMutationLock(
                networkSecretInput: networkSecretInput
            ).secretOutcome
        }
        return outcome
    }

    func runSelectedConfigWithoutMutationLock(
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

    func runConfigWithoutMutationLock(
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
        guard allowsLocalConfigurationMutation else { return }
        guard !isQuitting else { return }
        guard let config = runtimeSession.takePendingStartAfterApproval() else { return }
        if let helperRegistration {
            await helperRegistration.refresh()
            guard !isQuitting else { return }
            guard helperRegistration.state == .enabled else {
                runtimeSession.restorePendingStartAfterApprovalIfEmpty(config)
                setLastError(
                    "Privileged helper is still not enabled. Approve EasyTier in "
                        + "System Settings > Login Items & Extensions, then try again.",
                    kind: .helperPermission
                )
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
        guard allowsLocalConfigurationMutation, !selectedConfigIsRuntimeManaged else { return }
        await withRuntimeMutation {
            await stopSelectedConfigWithoutMutationLock()
        }
    }

    func stopSelectedConfigWithoutMutationLock() async {
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
        guard allowsLocalConfigurationMutation, !selectedConfigIsRuntimeManaged else { return .none }
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
        guard allowsLocalConfigurationMutation else {
            return .failed("Config Server manages this workspace.")
        }
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

    func restartConfig(
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

    nonisolated static func configWithoutNetworkSecret(_ config: NetworkConfig) -> NetworkConfig {
        var config = config
        config.network_secret = nil
        return config
    }

    public func toggleSelectedConfigConnection() async {
        guard allowsLocalConfigurationMutation, !selectedConfigIsRuntimeManaged else { return }
        await withRuntimeMutation {
            if selectedConfigCanStop {
                await stopSelectedConfigWithoutMutationLock()
            } else {
                _ = await runSelectedConfigWithoutMutationLock()
            }
        }
    }

    func validateConfigForCurrentRuntime(_ config: NetworkConfig, replacing instance: NetworkInstance? = nil) throws {
        try NetworkConfigValidator.validate(config, activeConfigs: activeConfigsForValidation(excluding: instance))
    }

    func activeConfigsForValidation(excluding excludedInstance: NetworkInstance?) -> [NetworkConfig] {
        instances.compactMap { instance in
            if let excludedInstance, isSameRuntimeInstance(instance, excludedInstance) { return nil }
            return config(matching: instance)
        }
    }

    func isSameRuntimeInstance(_ lhs: NetworkInstance, _ rhs: NetworkInstance) -> Bool {
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

}
