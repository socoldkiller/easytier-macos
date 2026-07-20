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
        let runsLegacyMigration = environment["EASYTIER_KEYCHAIN_TEST_LEGACY_MIGRATION"] != "0"
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
        let migrationConfig = NetworkConfig(
            instance_id: "keychain-migrate-\(suffix)",
            network_name: "keychain-migrate-\(suffix)"
        )
        let accounts = [saveConfig.network_name, migrationConfig.network_name]

        defer {
            for account in accounts {
                _ = deleteItem(
                    service: service,
                    account: account,
                    accessGroup: accessGroup,
                    dataProtection: false
                )
                _ = deleteItem(
                    service: service,
                    account: account,
                    accessGroup: accessGroup,
                    dataProtection: true
                )
            }
        }

        _ = try await store.save("integration-save-secret", for: saveConfig)
        try requireModernItem(
            service: service,
            account: saveConfig.network_name,
            accessGroup: accessGroup
        )
        try requireLegacyItemAbsent(
            service: service,
            account: saveConfig.network_name,
            accessGroup: accessGroup
        )

        if runsLegacyMigration {
            try addLegacyFixture(
                "integration-migration-secret",
                service: service,
                account: migrationConfig.network_name,
                accessGroup: accessGroup
            )
            let migrated = try await store.secret(
                for: migrationConfig,
                purpose: .reveal,
                reason: "Migrate an EasyTier Keychain integration fixture."
            )
            guard migrated?.secret == "integration-migration-secret" else {
                throw HarnessError("legacy migration returned an unexpected value")
            }
            try requireModernItem(
                service: service,
                account: migrationConfig.network_name,
                accessGroup: accessGroup
            )
            try requireLegacyItemAbsent(
                service: service,
                account: migrationConfig.network_name,
                accessGroup: accessGroup
            )
        } else {
            print("Legacy Keychain migration skipped because this runner has no interactive user session.")
        }

        for account in accounts {
            try requireDeleteSucceeded(
                deleteItem(
                    service: service,
                    account: account,
                    accessGroup: accessGroup,
                    dataProtection: false
                )
            )
            try requireDeleteSucceeded(
                deleteItem(
                    service: service,
                    account: account,
                    accessGroup: accessGroup,
                    dataProtection: true
                )
            )
        }
        store.invalidateAuthenticationSession()
    }

    private static func addLegacyFixture(
        _ secret: String,
        service: String,
        account: String,
        accessGroup: String?
    ) throws {
        var query = baseQuery(
            service: service,
            account: account,
            accessGroup: accessGroup,
            dataProtection: false
        )
        query[kSecValueData as String] = Data(secret.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        try requireStatus(SecItemAdd(query as CFDictionary, nil), operation: "add legacy fixture")
    }

    private static func requireModernItem(
        service: String,
        account: String,
        accessGroup: String?
    ) throws {
        var query = baseQuery(
            service: service,
            account: account,
            accessGroup: accessGroup,
            dataProtection: true
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

    private static func requireLegacyItemAbsent(
        service: String,
        account: String,
        accessGroup: String?
    ) throws {
        var query = baseQuery(
            service: service,
            account: account,
            accessGroup: accessGroup,
            dataProtection: false
        )
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        guard status == errSecItemNotFound else {
            throw NetworkSecretStoreError.keychain(status)
        }
    }

    private static func deleteItem(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) -> OSStatus {
        SecItemDelete(
            baseQuery(
                service: service,
                account: account,
                accessGroup: accessGroup,
                dataProtection: dataProtection
            ) as CFDictionary
        )
    }

    private static func baseQuery(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: dataProtection,
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

    private static func requireStatus(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            throw HarnessError("\(operation) failed with OSStatus \(status): \(message)")
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
