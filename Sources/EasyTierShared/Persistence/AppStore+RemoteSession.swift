import Foundation
import Observation
import TOML

extension EasyTierAppStore {
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

    func verifyRemoteConfigRestart(_ session: RemoteConfigSession) async -> RemoteNetworkConfigDocument? {
        for attempt in 0..<Self.remoteConfigConfirmationAttempts {
            guard remoteConfigSession?.requestID == session.requestID else { return nil }
            try? await refreshRuntimeThrowing()

            var rpcURLs = [session.rpcURL]
            if let member = selectedLiveMemberStatuses.first(where: { $0.instanceID == session.instanceID }),
               let ip = member.copyableIPv4Address,
               let currentURL = URL(string: "tcp://\(ip):\(AppMode.defaultRPCListenPort)"),
               currentURL != session.rpcURL {
                rpcURLs.insert(currentURL, at: 0)
            }

            for rpcURL in rpcURLs {
                if let document = try? await EasyTierRemoteRPCClient(rpcURL: rpcURL, client: runtimeClient)
                    .getConfigDocument(instanceID: session.instanceID),
                   document.config == session.config {
                    return document
                }
            }

            if attempt + 1 < Self.remoteConfigConfirmationAttempts {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return nil
    }

    func failRemoteConfigApply(requestID: UUID, message: String) {
        guard var current = remoteConfigSession, current.requestID == requestID else { return }
        current.applyState = .failed(message)
        remoteConfigSession = current
        recordNotice("Remote configuration apply failed: \(message)")
    }

    func clearRemoteAppliedStateAfterDelay(requestID: UUID) {
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

    func applyPersistedMode(_ mode: AppMode, magicDNSSettings: MagicDNSSettings) async {
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
               networkSecretInput.isSaved {
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

}
