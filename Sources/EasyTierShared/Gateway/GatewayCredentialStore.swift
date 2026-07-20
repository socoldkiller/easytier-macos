import Foundation
import Security

package enum GatewayCredentialSecret: Codable, Equatable, Sendable {
    case cloudflare(apiToken: String)
    case aliyun(accessKeyID: String, accessKeySecret: String)

    private enum CodingKeys: String, CodingKey {
        case provider
        case apiToken = "api_token"
        case accessKeyID = "access_key_id"
        case accessKeySecret = "access_key_secret"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(GatewayDNSProvider.self, forKey: .provider) {
        case .cloudflare:
            self = .cloudflare(apiToken: try container.decode(String.self, forKey: .apiToken))
        case .aliyun:
            self = .aliyun(
                accessKeyID: try container.decode(String.self, forKey: .accessKeyID),
                accessKeySecret: try container.decode(String.self, forKey: .accessKeySecret)
            )
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .cloudflare(apiToken):
            try container.encode(GatewayDNSProvider.cloudflare, forKey: .provider)
            try container.encode(apiToken, forKey: .apiToken)
        case let .aliyun(accessKeyID, accessKeySecret):
            try container.encode(GatewayDNSProvider.aliyun, forKey: .provider)
            try container.encode(accessKeyID, forKey: .accessKeyID)
            try container.encode(accessKeySecret, forKey: .accessKeySecret)
        }
    }
}

package protocol GatewayCredentialStoring: Sendable {
    func save(_ secret: GatewayCredentialSecret, id: String) async throws
    func load(id: String) async throws -> GatewayCredentialSecret?
    func remove(id: String) async throws
    func resolve(_ descriptors: [GatewayDNSCredentialDescriptor]) async throws -> GatewaySecrets
}

package actor SystemGatewayCredentialStore: GatewayCredentialStoring {
    private static let service = "com.kkrainbow.easytier.gateway.dns-credentials"

    package init() {}

    package func save(_ secret: GatewayCredentialSecret, id: String) throws {
        let data = try JSONEncoder().encode(secret)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(id: id) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw GatewayCredentialStoreError.keychain(status)
        }
        var add = query(id: id)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GatewayCredentialStoreError.keychain(addStatus)
        }
    }

    package func load(id: String) throws -> GatewayCredentialSecret? {
        var lookup = query(id: id)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw GatewayCredentialStoreError.keychain(status)
        }
        return try JSONDecoder().decode(GatewayCredentialSecret.self, from: data)
    }

    package func remove(id: String) throws {
        let status = SecItemDelete(query(id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GatewayCredentialStoreError.keychain(status)
        }
    }

    package func resolve(_ descriptors: [GatewayDNSCredentialDescriptor]) throws -> GatewaySecrets {
        var cloudflare: [String: GatewayCloudflareSecret] = [:]
        var aliyun: [String: GatewayAliyunSecret] = [:]
        for descriptor in descriptors {
            guard let secret = try load(id: descriptor.id) else { continue }
            switch (descriptor.provider, secret) {
            case let (.cloudflare, .cloudflare(apiToken)):
                cloudflare[descriptor.id] = GatewayCloudflareSecret(apiToken: apiToken)
            case let (.aliyun, .aliyun(accessKeyID, accessKeySecret)):
                aliyun[descriptor.id] = GatewayAliyunSecret(
                    accessKeyID: accessKeyID,
                    accessKeySecret: accessKeySecret
                )
            default:
                continue
            }
        }
        return GatewaySecrets(cloudflare: cloudflare, aliyun: aliyun)
    }

    private func query(id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

package enum GatewayCredentialStoreError: LocalizedError, Sendable {
    case keychain(OSStatus)

    package var errorDescription: String? {
        switch self {
        case let .keychain(status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Gateway credential Keychain error \(status)."
        }
    }
}
