import EasyTierShared
import Foundation
import LocalAuthentication
import Security

@main
struct EasyTierKeychainIntegrationHarness {
    static func main() async {
        do {
            try await run()
            print("Data Protection Keychain integration test passed.")
        } catch NetworkSecretStoreError.keychain(errSecInteractionNotAllowed)
            where ProcessInfo.processInfo.environment["EASYTIER_KEYCHAIN_TEST_ALLOW_HEADLESS_SKIP"] == "1"
        {
            print("Data Protection Keychain integration skipped because this runner has no interactive user session.")
        } catch {
            fputs("Data Protection Keychain integration test failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let service = environment["EASYTIER_KEYCHAIN_TEST_SERVICE"]
            ?? "com.kkrainbow.easytier.mac.keychain-test.\(UUID().uuidString.lowercased())"
        let accessGroup = environment["EASYTIER_KEYCHAIN_ACCESS_GROUP"]?.nilIfEmpty
        let namespace = NetworkSecretKeychainNamespace(
            service: service,
            accessGroup: accessGroup
        )
        let store = SystemNetworkSecretStore(namespace: namespace)
        let suffix = UUID().uuidString.lowercased()
        let saveConfig = NetworkConfig(
            instance_id: "keychain-save-\(suffix)",
            network_name: "keychain-save-\(suffix)"
        )
        let account = saveConfig.instance_id

        defer {
            _ = deleteItem(service: service, account: account, accessGroup: accessGroup)
        }

        try await store.save("integration-save-secret", for: saveConfig)
        try requireModernItem(
            service: service,
            account: account,
            accessGroup: accessGroup
        )
        let loaded = try await store.secret(
            for: saveConfig,
            purpose: .reveal,
            reason: "Read an EasyTier Keychain integration fixture."
        )
        guard loaded == "integration-save-secret" else {
            throw HarnessError("Data Protection Keychain returned an unexpected value")
        }

        try await store.deleteSecret(for: saveConfig)
        try requireDeleteSucceeded(deleteItem(service: service, account: account, accessGroup: accessGroup))
        store.invalidateAuthenticationSession()
    }

    private static func requireModernItem(
        service: String,
        account: String,
        accessGroup: String?
    ) throws {
        var query = baseQuery(
            service: service,
            account: account,
            accessGroup: accessGroup
        )
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        var status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound {
            let context = LAContext()
            context.interactionNotAllowed = true
            defer { context.invalidate() }

            query.removeValue(forKey: kSecReturnAttributes as String)
            query.removeValue(forKey: kSecUseAuthenticationUI as String)
            query[kSecReturnData as String] = true
            query[kSecUseAuthenticationContext as String] = context
            status = SecItemCopyMatching(query as CFDictionary, nil)
        }
        guard status == errSecSuccess || status == errSecInteractionNotAllowed else {
            throw NetworkSecretStoreError.keychain(status)
        }
    }

    private static func deleteItem(
        service: String,
        account: String,
        accessGroup: String?
    ) -> OSStatus {
        SecItemDelete(
            baseQuery(
                service: service,
                account: account,
                accessGroup: accessGroup
            ) as CFDictionary
        )
    }

    private static func baseQuery(
        service: String,
        account: String,
        accessGroup: String?
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func requireDeleteSucceeded(_ status: OSStatus) throws {
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NetworkSecretStoreError.keychain(status)
        }
    }

}

private struct HarnessError: LocalizedError {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
