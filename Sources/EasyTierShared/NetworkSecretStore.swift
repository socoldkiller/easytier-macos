import Foundation
import LocalAuthentication
import Security

public protocol NetworkSecretStore: Sendable {
    func save(_ secret: String, for config: NetworkConfig) throws
    func secret(for config: NetworkConfig, reason: String?) throws -> String?
    func deleteSecret(for config: NetworkConfig) throws
    func containsSecret(for config: NetworkConfig) -> Bool
    func canAutofillWithBiometrics() -> Bool
}

public enum NetworkSecretStoreError: LocalizedError {
    case accessControl(String)
    case invalidData
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .accessControl(message):
            "Keychain access control failed: \(message)"
        case .invalidData:
            "Keychain secret is not valid UTF-8."
        case let .keychain(status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        }
    }
}

public struct SystemNetworkSecretStore: NetworkSecretStore {
    public static let service = "com.kkrainbow.easytier.mac.network-secret"

    public init() {}

    public func save(_ secret: String, for config: NetworkConfig) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(for: config)
        let attributes = try itemAttributes(data: data, config: config, requiresUserPresence: true)
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try addItem(query: query, attributes: attributes, data: data, config: config)
        } else if status == errSecMissingEntitlement {
            let fallbackAttributes = try itemAttributes(data: data, config: config, requiresUserPresence: false)
            let fallbackStatus = SecItemUpdate(query as CFDictionary, fallbackAttributes as CFDictionary)
            if fallbackStatus == errSecItemNotFound {
                try addItem(query: query, attributes: fallbackAttributes, data: data, config: config)
            } else if fallbackStatus != errSecSuccess {
                throw NetworkSecretStoreError.keychain(fallbackStatus)
            }
        } else if status != errSecSuccess {
            throw NetworkSecretStoreError.keychain(status)
        }
    }

    public func secret(for config: NetworkConfig, reason: String?) throws -> String? {
        var query = baseQuery(for: config)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let reason {
            let context = LAContext()
            context.localizedReason = reason
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NetworkSecretStoreError.keychain(status) }
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw NetworkSecretStoreError.invalidData
        }
        return secret
    }

    public func deleteSecret(for config: NetworkConfig) throws {
        let status = SecItemDelete(baseQuery(for: config) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NetworkSecretStoreError.keychain(status)
        }
    }

    public func containsSecret(for config: NetworkConfig) -> Bool {
        var query = baseQuery(for: config)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func canAutofillWithBiometrics() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    private func baseQuery(for config: NetworkConfig) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: config.instance_id,
        ]
    }

    private func addItem(query: [String: Any], attributes: [String: Any], data: Data, config: NetworkConfig) throws {
        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecMissingEntitlement && attributes[kSecAttrAccessControl as String] != nil {
            try addItem(
                query: query,
                attributes: itemAttributes(data: data, config: config, requiresUserPresence: false),
                data: data,
                config: config
            )
            return
        }
        guard addStatus == errSecSuccess else { throw NetworkSecretStoreError.keychain(addStatus) }
    }

    private func itemAttributes(data: Data, config: NetworkConfig, requiresUserPresence: Bool) throws -> [String: Any] {
        var attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: config.network_name,
            kSecAttrComment as String: "EasyTier network secret for \(config.network_name)",
        ]
        guard requiresUserPresence else { return attributes }

        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.userPresence],
            &error
        ) else {
            throw NetworkSecretStoreError.accessControl(error?.takeRetainedValue().localizedDescription ?? "unknown error")
        }
        attributes[kSecAttrAccessControl as String] = access
        return attributes
    }
}
