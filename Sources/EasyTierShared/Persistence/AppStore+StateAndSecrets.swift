import Foundation
import Observation
import TOML

extension EasyTierAppStore {
    func stateForStorage() throws -> WorkspacePersistenceState {
        let configs = configs.map(Self.configWithoutNetworkSecret)
        let selectedLocalConfigID = selectedConfigID.flatMap { selectedID in
            configs.contains(where: { $0.id == selectedID }) ? selectedID : nil
        }
        let persistedLocalConfigID = persistedSelectedConfigID.flatMap { selectedID in
            configs.contains(where: { $0.id == selectedID }) ? selectedID : nil
        }
        return WorkspacePersistenceState(
            configs: configs,
            selectedConfigID: selectedLocalConfigID ?? persistedLocalConfigID,
            mode: mode,
            vpnOnDemandEnabled: vpnOnDemandEnabled,
            runtimeIntents: runtimeIntents,
            reversedPortForwardFingerprints: reversedPortForwardFingerprints,
            magicDNSSettings: magicDNSSettings,
            peerSubscriptions: peerSubscriptions
        )
    }

    func commitPersistenceState(_ state: WorkspacePersistenceState) async throws {
        do {
            try await database.saveWorkspace(state)
            applyPersistenceState(state)
            persistenceHealth = .ready
        } catch {
            persistenceHealth = .unavailable(PersistenceFailure(
                message: error.localizedDescription,
                databaseURL: database.databaseURL
            ))
            throw error
        }
    }

    func applyPersistenceState(_ state: WorkspacePersistenceState) {
        let transientRuntimeSelection = isConfigServerManaged ? selectedConfigID : nil
        configs = state.configs
        persistedSelectedConfigID = state.selectedConfigID
        selectedConfigID = isConfigServerManaged ? transientRuntimeSelection : state.selectedConfigID
        mode = state.mode
        vpnOnDemandEnabled = state.vpnOnDemandEnabled
        runtimeIntents = state.runtimeIntents
        reversedPortForwardFingerprints = state.reversedPortForwardFingerprints
        magicDNSSettings = state.magicDNSSettings
        peerSubscriptions = state.peerSubscriptions
    }

    func configsWithSecretsStored(_ configs: [NetworkConfig]) async throws -> [NetworkConfig] {
        var configs = configs
        for index in configs.indices {
            guard let secret = configs[index].network_secret?.nilIfEmpty else { continue }
            try await saveNetworkSecretToKeychain(secret, for: configs[index])
            configs[index].network_secret = nil
        }
        return configs
    }

    func configWithKeychainSecret(
        _ config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose,
        reason: String,
        useSessionCache: Bool = true
    ) async throws -> NetworkConfig {
        guard config.network_secret?.nilIfEmpty == nil else { return config }
        if useSessionCache, let cachedSecret = cachedNetworkSecret(for: config) {
            return Self.config(config, withNetworkSecret: cachedSecret)
        }
        let authenticationGeneration = networkSecretAccessGeneration
        let result = try await networkSecretStore.secret(
            for: config,
            purpose: purpose,
            reason: reason
        )
        guard authenticationGeneration == networkSecretAccessGeneration else {
            throw CancellationError()
        }
        guard let result else { return config }
        cacheNetworkSecret(result, for: config)
        return Self.config(config, withNetworkSecret: result)
    }

    func configWithResolvedNetworkSecret(
        _ config: NetworkConfig,
        input: NetworkSecretInput?,
        purpose: NetworkSecretAccessPurpose,
        reason: String
    ) async throws -> ResolvedNetworkSecretConfig {
        guard let input = normalizedNetworkSecretInput(input) else {
            return ResolvedNetworkSecretConfig(
                config: try await configWithKeychainSecret(
                    config,
                    purpose: purpose,
                    reason: reason
                ),
                outcome: .none
            )
        }

        switch input {
        case let .saved(secret):
            cacheNetworkSecret(secret, for: config)
            return ResolvedNetworkSecretConfig(
                config: Self.config(config, withNetworkSecret: secret),
                outcome: .none
            )
        case let .edited(secret):
            try await saveNetworkSecretToKeychain(secret, for: config)
            return ResolvedNetworkSecretConfig(
                config: Self.config(config, withNetworkSecret: secret),
                outcome: NetworkSecretOperationOutcome(didPersistEditedSecret: true)
            )
        }
    }

    func normalizedNetworkSecretInput(
        _ input: NetworkSecretInput?
    ) -> NetworkSecretInput? {
        guard let input, let value = input.value.nilIfEmpty else { return nil }
        switch input {
        case .saved:
            return .saved(value)
        case .edited:
            return .edited(value)
        }
    }

    func cachedNetworkSecret(for config: NetworkConfig) -> String? {
        guard cachedNetworkSecret?.namespace == Self.secretNamespace(for: config) else { return nil }
        return cachedNetworkSecret?.value
    }

    func cacheNetworkSecret(_ secret: String, for config: NetworkConfig) {
        guard let secret = secret.nilIfEmpty else { return }
        cachedNetworkSecret = CachedNetworkSecret(
            namespace: Self.secretNamespace(for: config),
            value: secret
        )
    }

    func clearCachedNetworkSecret(for config: NetworkConfig) {
        guard cachedNetworkSecret?.namespace == Self.secretNamespace(for: config) else { return }
        cachedNetworkSecret = nil
    }

    static func config(
        _ config: NetworkConfig,
        withNetworkSecret secret: String
    ) -> NetworkConfig {
        var config = config
        config.network_secret = secret
        return config
    }

    func invalidateSecretAuthenticationSession() {
        cachedNetworkSecret = nil
        networkSecretSessionRevision &+= 1
        networkSecretAccessGeneration &+= 1
        networkSecretStore.invalidateAuthenticationSession()
    }

    static func secretNamespace(for config: NetworkConfig) -> String {
        config.instance_id
    }

    func encodedTOML(for config: NetworkConfig) throws -> String {
        try NetworkConfigTOMLCodec.encode(config, magicDNSSettings: magicDNSSettings)
    }

    func uniquelyMatchedInstance(named networkName: String) -> NetworkInstance? {
        let matchingConfigs = configs.filter { $0.network_name == networkName }
        guard matchingConfigs.count <= 1 else { return nil }

        let matches = instances.filter { instance in
            instance.instance_id == networkName
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func uniquelyMatchedConfig(named networkName: String) -> NetworkConfig? {
        let matches = configs.filter { $0.network_name == networkName }
        return matches.count == 1 ? matches[0] : nil
    }

    func runningMagicDNSConfigNames() -> [String] {
        configs
            .filter { $0.enable_magic_dns == true && runningInstance(matching: $0) != nil }
            .map(\.network_name)
            .sorted()
    }

    func localConfig(matching instance: NetworkInstance) -> NetworkConfig? {
        if let byID = configs.first(where: { $0.instance_id == instance.instance_id }) { return byID }
        guard instance.instance_id == instance.name else { return nil }
        let matches = configs.filter { $0.network_name == instance.name }
        return matches.count == 1 ? matches[0] : nil
    }

    func reconcileSelectedConfigWithRuntimeManagedConfigs(
        previousInstances: [NetworkInstance] = []
    ) {
        switch configurationAuthority {
        case .local:
            guard let selectedConfigID else { return }
            guard !configs.contains(where: { $0.id == selectedConfigID }) else { return }
            let persistedLocalConfigID = persistedSelectedConfigID.flatMap { selectedID in
                configs.contains(where: { $0.id == selectedID }) ? selectedID : nil
            }
            self.selectedConfigID = persistedLocalConfigID ?? configs.first?.id

        case .configServer:
            let managedConfigs = runtimeManagedConfigs
            if let selectedConfigID,
               managedConfigs.contains(where: { $0.id == selectedConfigID }) {
                return
            }
            if let selectedConfigID,
               let previousName = previousInstances.first(where: { $0.instance_id == selectedConfigID })?.name,
               let sameNetwork = managedConfigs.first(where: { $0.network_name == previousName }) {
                self.selectedConfigID = sameNetwork.id
                return
            }
            selectedConfigID = managedConfigs.first?.id
        }
    }

    func selectConfig(offset: Int) async {
        let configs = presentedConfigs
        guard !configs.isEmpty else {
            await selectConfig(id: nil)
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

        await selectConfig(id: nextID)
    }

    @discardableResult
    func busy(
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

    func setLastError(_ error: Error) {
        setLastError(Self.errorMessage(for: error), kind: Self.lastErrorKind(for: error))
    }

    static func errorMessage(for error: Error, toml: String? = nil) -> String {
        if let tomlError = error as? TOMLDecodingError {
            let message = tomlError.description
            if case let .invalidSyntax(line, column, _) = tomlError,
               let toml,
               let character = tomlCharacterDescription(in: toml, line: line, column: column) {
                return "\(message). Character at line \(line), column \(column): \(character)"
            }
            return message
        }
        return error.localizedDescription
    }

    static func tomlCharacterDescription(in toml: String, line: Int, column: Int) -> String? {
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

    func setLastError(_ message: String, kind: LastErrorKind? = nil) {
        lastErrorKind = kind
        lastError = message
    }

    static func lastErrorKind(for error: Error) -> LastErrorKind? {
        switch error {
        case PrivilegedHelperError.needsRegistration:
            return .helperPermission
        case let PrivilegedHelperError.helperReported(payload) where payload.code == "helperRequiresApproval":
            return .helperPermission
        default:
            return nil
        }
    }

    func log(_ message: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        logLines.insert(LogEntry(text: "[\(timestamp)] \(message)"), at: 0)
        if logLines.count > 300 { logLines.removeLast(logLines.count - 300) }
    }

    // MARK: - Peer Subscriptions

}
