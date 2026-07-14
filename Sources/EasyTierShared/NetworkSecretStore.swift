import Foundation
import LocalAuthentication
import Security

public protocol NetworkSecretStore: Sendable {
    func save(_ secret: String, for config: NetworkConfig) throws
    func secret(for config: NetworkConfig, reason: String?) throws -> String?
    func deleteSecret(for config: NetworkConfig) throws
    func containsSecret(for config: NetworkConfig) throws -> Bool
    func migrateSecret(from oldConfig: NetworkConfig, to newConfig: NetworkConfig) throws
    func invalidateAuthenticationSession()
}

public extension NetworkSecretStore {
    func migrateSecret(from oldConfig: NetworkConfig, to newConfig: NetworkConfig) throws {
        guard let secret = try secret(for: oldConfig, reason: nil) else { return }
        try save(secret, for: newConfig)
        try deleteSecret(for: oldConfig)
    }

    func invalidateAuthenticationSession() {}
}

public enum NetworkSecretStoreError: LocalizedError {
    case accessControl(String)
    case invalidData
    case missingEntitlement
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .accessControl(message):
            "Keychain access control failed: \(message)"
        case .invalidData:
            "Keychain secret is not valid UTF-8."
        case .missingEntitlement:
            "EasyTier is not signed with the Data Protection Keychain entitlements required to protect network secrets. Reinstall a correctly signed build."
        case let .keychain(status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        }
    }

    public var isUserCancellation: Bool {
        guard case let .keychain(status) = self else { return false }
        return status == errSecUserCanceled
    }
}

protocol NetworkSecretKeychainClient {
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?)
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct SystemNetworkSecretKeychainClient: NetworkSecretKeychainClient {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

public final class SystemNetworkSecretStore: NetworkSecretStore, @unchecked Sendable {
    public static let service = "com.kkrainbow.easytier.mac.network-secret"

    private enum Backend {
        case dataProtection
        case legacy
    }

    private enum ItemPresence {
        case absent
        case present
    }

    private let keychain: any NetworkSecretKeychainClient
    private let contextFactory: () -> LAContext
    private let contextLock = NSLock()
    private var authenticationContexts: [String: LAContext] = [:]

    public convenience init() {
        self.init(keychain: SystemNetworkSecretKeychainClient())
    }

    init(
        keychain: any NetworkSecretKeychainClient,
        contextFactory: @escaping () -> LAContext = LAContext.init
    ) {
        self.keychain = keychain
        self.contextFactory = contextFactory
    }

    public func save(_ secret: String, for config: NetworkConfig) throws {
        let data = Data(secret.utf8)
        let attributes = try itemAttributes(data: data, config: config)
        let context = authenticationContext(
            for: config.network_name,
            reason: "Update the saved secret for network \"\(config.network_name)\"."
        )
        var query = baseQuery(for: config, backend: .dataProtection)
        query[kSecUseAuthenticationContext as String] = context
        let status = keychain.update(query, attributes: attributes)
        if status == errSecItemNotFound {
            do {
                try addItem(
                    query: baseQuery(for: config, backend: .dataProtection),
                    attributes: attributes
                )
            } catch {
                discardAuthenticationContext(for: config.network_name, matching: context)
                throw error
            }
        } else {
            do {
                try requireSuccess(status)
            } catch {
                discardAuthenticationContext(for: config.network_name, matching: context)
                throw error
            }
        }

        _ = delete(config: config, backend: .legacy, context: context)
    }

    public func secret(for config: NetworkConfig, reason: String?) throws -> String? {
        let context = authenticationContext(for: config.network_name, reason: reason)
        let modernResult = read(config: config, backend: .dataProtection, context: context)
        switch modernResult.status {
        case errSecSuccess:
            do {
                return try decodeSecret(modernResult.result)
            } catch {
                discardAuthenticationContext(for: config.network_name, matching: context)
                throw error
            }
        case errSecItemNotFound:
            break
        default:
            discardAuthenticationContext(for: config.network_name, matching: context)
            try requireSuccess(modernResult.status)
        }

        let legacyResult = read(config: config, backend: .legacy, context: context)
        switch legacyResult.status {
        case errSecSuccess:
            let secret: String
            do {
                secret = try decodeSecret(legacyResult.result)
            } catch {
                discardAuthenticationContext(for: config.network_name, matching: context)
                throw error
            }
            try save(secret, for: config)
            return secret
        case errSecItemNotFound:
            discardAuthenticationContext(for: config.network_name, matching: context)
            return nil
        default:
            discardAuthenticationContext(for: config.network_name, matching: context)
            try requireSuccess(legacyResult.status)
            return nil
        }
    }

    public func deleteSecret(for config: NetworkConfig) throws {
        let context = authenticationContext(
            for: config.network_name,
            reason: "Delete the saved secret for network \"\(config.network_name)\"."
        )
        let modernStatus = delete(config: config, backend: .dataProtection, context: context)
        let legacyStatus = delete(config: config, backend: .legacy, context: context)
        discardAuthenticationContext(for: config.network_name)
        try requireSuccessOrNotFound(modernStatus)
        try requireSuccessOrNotFound(legacyStatus)
    }

    public func containsSecret(for config: NetworkConfig) throws -> Bool {
        if try presence(config: config, backend: .dataProtection) == .present {
            return true
        }
        return try presence(config: config, backend: .legacy) == .present
    }

    public func migrateSecret(from oldConfig: NetworkConfig, to newConfig: NetworkConfig) throws {
        guard oldConfig.network_name != newConfig.network_name else { return }

        let attributes: [String: Any] = [
            kSecAttrAccount as String: newConfig.network_name,
            kSecAttrLabel as String: newConfig.network_name,
            kSecAttrComment as String: "EasyTier network secret for \(newConfig.network_name)",
        ]
        let context = authenticationContext(
            for: oldConfig.network_name,
            reason: "Rename the saved secret for network \"\(oldConfig.network_name)\"."
        )
        var modernQuery = baseQuery(for: oldConfig, backend: .dataProtection)
        modernQuery[kSecUseAuthenticationContext as String] = context
        let modernStatus = keychain.update(
            modernQuery,
            attributes: attributes
        )
        if modernStatus == errSecSuccess {
            _ = delete(config: oldConfig, backend: .legacy, context: context)
            moveAuthenticationContext(
                from: oldConfig.network_name,
                to: newConfig.network_name,
                matching: context
            )
            return
        }
        guard modernStatus == errSecItemNotFound else {
            discardAuthenticationContext(for: oldConfig.network_name, matching: context)
            try requireSuccess(modernStatus)
            return
        }

        var legacyQuery = baseQuery(for: oldConfig, backend: .legacy)
        legacyQuery[kSecUseAuthenticationContext as String] = context
        let legacyStatus = keychain.update(
            legacyQuery,
            attributes: attributes
        )
        if legacyStatus == errSecSuccess {
            moveAuthenticationContext(
                from: oldConfig.network_name,
                to: newConfig.network_name,
                matching: context
            )
            return
        }
        discardAuthenticationContext(for: oldConfig.network_name, matching: context)
        try requireSuccessOrNotFound(legacyStatus)
    }

    public func invalidateAuthenticationSession() {
        contextLock.lock()
        let contexts = Array(authenticationContexts.values)
        authenticationContexts.removeAll()
        contextLock.unlock()

        contexts.forEach { $0.invalidate() }
    }

    private func read(
        config: NetworkConfig,
        backend: Backend,
        context: LAContext?
    ) -> (status: OSStatus, result: CFTypeRef?) {
        var query = baseQuery(for: config, backend: backend)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        return keychain.copyMatching(query)
    }

    private func presence(config: NetworkConfig, backend: Backend) throws -> ItemPresence {
        var query = baseQuery(for: config, backend: backend)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Existence checks must never surface authentication UI. Apple
        // recommends skipping protected items for broad/non-reading queries.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip

        let status = keychain.copyMatching(query).status
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed:
            return .present
        case errSecItemNotFound:
            return .absent
        default:
            try requireSuccess(status)
            return .absent
        }
    }

    private func baseQuery(for config: NetworkConfig, backend: Backend) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: config.network_name,
        ]
        if backend == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func addItem(query: [String: Any], attributes: [String: Any]) throws {
        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        try requireSuccess(keychain.add(addQuery))
    }

    private func itemAttributes(data: Data, config: NetworkConfig) throws -> [String: Any] {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.userPresence],
            &error
        ) else {
            throw NetworkSecretStoreError.accessControl(
                error?.takeRetainedValue().localizedDescription ?? "unknown error"
            )
        }

        return [
            kSecValueData as String: data,
            kSecAttrLabel as String: config.network_name,
            kSecAttrComment as String: "EasyTier network secret for \(config.network_name)",
            kSecAttrAccessControl as String: access,
        ]
    }

    private func authenticationContext(for networkName: String, reason: String?) -> LAContext {
        contextLock.lock()
        defer { contextLock.unlock() }
        if let context = authenticationContexts[networkName] {
            return context
        }

        let context = contextFactory()
        context.localizedReason = reason ?? "Access the saved secret for network \"\(networkName)\"."
        context.touchIDAuthenticationAllowableReuseDuration = 300
        authenticationContexts[networkName] = context
        return context
    }

    private func discardAuthenticationContext(for networkName: String, matching expected: LAContext? = nil) {
        contextLock.lock()
        let stored = authenticationContexts[networkName]
        if expected == nil || stored === expected {
            authenticationContexts.removeValue(forKey: networkName)
        }
        contextLock.unlock()

        if expected == nil || stored === expected {
            stored?.invalidate()
        }
    }

    private func moveAuthenticationContext(from oldNetworkName: String, to newNetworkName: String, matching expected: LAContext) {
        contextLock.lock()
        guard authenticationContexts[oldNetworkName] === expected else {
            contextLock.unlock()
            return
        }
        let displaced = authenticationContexts[newNetworkName]
        authenticationContexts.removeValue(forKey: oldNetworkName)
        authenticationContexts[newNetworkName] = expected
        contextLock.unlock()

        if displaced !== expected {
            displaced?.invalidate()
        }
    }

    private func decodeSecret(_ result: CFTypeRef?) throws -> String {
        guard let data = result as? Data,
              let secret = String(data: data, encoding: .utf8)
        else {
            throw NetworkSecretStoreError.invalidData
        }
        return secret
    }

    private func delete(config: NetworkConfig, backend: Backend, context: LAContext? = nil) -> OSStatus {
        var query = baseQuery(for: config, backend: backend)
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        return keychain.delete(query)
    }

    private func requireSuccess(_ status: OSStatus) throws {
        guard status != errSecMissingEntitlement else {
            throw NetworkSecretStoreError.missingEntitlement
        }
        guard status == errSecSuccess else {
            throw NetworkSecretStoreError.keychain(status)
        }
    }

    private func requireSuccessOrNotFound(_ status: OSStatus) throws {
        guard status == errSecSuccess || status == errSecItemNotFound else {
            try requireSuccess(status)
            return
        }
    }
}
