import Foundation
import LocalAuthentication
import Security
import Testing
@testable import EasyTierShared

@Test func missingEntitlementNeverFallsBackToAnUnprotectedKeychainItem() throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.updateResults = [errSecItemNotFound]
    keychain.addResults = [errSecMissingEntitlement]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let config = NetworkConfig(instance_id: "missing-entitlement-id", network_name: "office")

    do {
        try store.save("secret", for: config)
        Issue.record("save should fail when the protected item cannot be added")
    } catch NetworkSecretStoreError.missingEntitlement {
        // Expected: signing failures must never trigger a weaker second write.
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(keychain.addQueries.count == 1)
    #expect(keychain.addQueries.first?[kSecAttrAccessControl as String] != nil)
    #expect(keychain.addQueries.first?[kSecUseDataProtectionKeychain as String] as? Bool == true)
}

@Test func missingEntitlementDuringUpdateDoesNotAttemptAnAddFallback() throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.updateResults = [errSecMissingEntitlement]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let config = NetworkConfig(instance_id: "update-entitlement-id", network_name: "office")

    do {
        try store.save("secret", for: config)
        Issue.record("save should fail when the protected item cannot be updated")
    } catch NetworkSecretStoreError.missingEntitlement {
        // Expected.
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(keychain.addQueries.isEmpty)
    #expect(keychain.updateQueries.count == 1)
}

@Test func authenticatedContextIsReusedUntilTheSessionIsInvalidated() throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.copyResults = [
        (errSecSuccess, Data("first".utf8) as CFData),
        (errSecSuccess, Data("second".utf8) as CFData),
        (errSecSuccess, Data("third".utf8) as CFData),
    ]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let config = NetworkConfig(instance_id: "context-id", network_name: "office")

    #expect(try store.secret(for: config, reason: "First access") == "first")
    #expect(try store.secret(for: config, reason: "Second access") == "second")

    let firstContext = try #require(
        keychain.copyQueries[0][kSecUseAuthenticationContext as String] as? LAContext
    )
    let secondContext = try #require(
        keychain.copyQueries[1][kSecUseAuthenticationContext as String] as? LAContext
    )
    #expect(firstContext === secondContext)
    #expect(keychain.copyQueries.allSatisfy {
        $0[kSecUseDataProtectionKeychain as String] as? Bool == true
    })

    store.invalidateAuthenticationSession()
    #expect(try store.secret(for: config, reason: "After sleep") == "third")
    let thirdContext = try #require(
        keychain.copyQueries[2][kSecUseAuthenticationContext as String] as? LAContext
    )
    #expect(firstContext !== thirdContext)
}

@Test func saveReusesTheAuthenticatedContextForProtectedUpdates() throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.copyResults = [(errSecSuccess, Data("original".utf8) as CFData)]
    keychain.updateResults = [errSecSuccess]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let config = NetworkConfig(instance_id: "save-context-id", network_name: "office")

    #expect(try store.secret(for: config, reason: "Read secret") == "original")
    try store.save("replacement", for: config)

    let readContext = try #require(
        keychain.copyQueries[0][kSecUseAuthenticationContext as String] as? LAContext
    )
    let updateContext = try #require(
        keychain.updateQueries[0][kSecUseAuthenticationContext as String] as? LAContext
    )
    #expect(readContext === updateContext)
}

@Test func failedProtectedUpdateDiscardsTheAuthenticationContext() throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.copyResults = [
        (errSecSuccess, Data("before".utf8) as CFData),
        (errSecSuccess, Data("after".utf8) as CFData),
    ]
    keychain.updateResults = [errSecUserCanceled]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let config = NetworkConfig(instance_id: "failed-update-context-id", network_name: "office")

    #expect(try store.secret(for: config, reason: "First read") == "before")
    #expect(throws: NetworkSecretStoreError.self) {
        try store.save("replacement", for: config)
    }
    #expect(try store.secret(for: config, reason: "Read after failed update") == "after")

    let firstContext = try #require(
        keychain.copyQueries[0][kSecUseAuthenticationContext as String] as? LAContext
    )
    let secondContext = try #require(
        keychain.copyQueries[1][kSecUseAuthenticationContext as String] as? LAContext
    )
    #expect(firstContext !== secondContext)
}

@Test func invalidSecretDataDiscardsTheAuthenticationContext() throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.copyResults = [
        (errSecSuccess, Data([0xFF]) as CFData),
        (errSecSuccess, Data("valid".utf8) as CFData),
    ]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let config = NetworkConfig(instance_id: "invalid-data-context-id", network_name: "office")

    #expect(throws: NetworkSecretStoreError.self) {
        try store.secret(for: config, reason: "Read invalid secret")
    }
    #expect(try store.secret(for: config, reason: "Read valid secret") == "valid")

    let firstContext = try #require(
        keychain.copyQueries[0][kSecUseAuthenticationContext as String] as? LAContext
    )
    let secondContext = try #require(
        keychain.copyQueries[1][kSecUseAuthenticationContext as String] as? LAContext
    )
    #expect(firstContext !== secondContext)
}

@Test func networkNameMigrationReusesTheAuthenticatedContext() throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.copyResults = [(errSecSuccess, Data("secret".utf8) as CFData)]
    keychain.updateResults = [errSecSuccess]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let oldConfig = NetworkConfig(instance_id: "migration-context-id", network_name: "before")
    var newConfig = oldConfig
    newConfig.network_name = "after"

    #expect(try store.secret(for: oldConfig, reason: "Read before rename") == "secret")
    try store.migrateSecret(from: oldConfig, to: newConfig)

    let readContext = try #require(
        keychain.copyQueries[0][kSecUseAuthenticationContext as String] as? LAContext
    )
    let updateContext = try #require(
        keychain.updateQueries[0][kSecUseAuthenticationContext as String] as? LAContext
    )
    #expect(readContext === updateContext)
}

@Test func legacyNetworkNameMigrationKeepsOneAuthenticationContext() throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.updateResults = [errSecItemNotFound, errSecSuccess]
    keychain.copyResults = [
        (errSecItemNotFound, nil),
        (errSecSuccess, Data("secret".utf8) as CFData),
    ]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let oldConfig = NetworkConfig(instance_id: "legacy-migration-context-id", network_name: "before")
    var newConfig = oldConfig
    newConfig.network_name = "after"

    try store.migrateSecret(from: oldConfig, to: newConfig)
    #expect(try store.secret(for: newConfig, reason: "Read after rename") == "secret")

    let modernUpdateContext = try #require(
        keychain.updateQueries[0][kSecUseAuthenticationContext as String] as? LAContext
    )
    let legacyUpdateContext = try #require(
        keychain.updateQueries[1][kSecUseAuthenticationContext as String] as? LAContext
    )
    let modernReadContext = try #require(
        keychain.copyQueries[0][kSecUseAuthenticationContext as String] as? LAContext
    )
    let legacyReadContext = try #require(
        keychain.copyQueries[1][kSecUseAuthenticationContext as String] as? LAContext
    )
    #expect(modernUpdateContext === legacyUpdateContext)
    #expect(modernUpdateContext === modernReadContext)
    #expect(modernUpdateContext === legacyReadContext)
    #expect(keychain.updateQueries[0][kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(keychain.updateQueries[1][kSecUseDataProtectionKeychain as String] == nil)
}

@Test func missingEntitlementDuringMigrationNeverFallsBackToTheLegacyKeychain() throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.updateResults = [errSecMissingEntitlement, errSecSuccess]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let oldConfig = NetworkConfig(instance_id: "migration-entitlement-id", network_name: "before")
    var newConfig = oldConfig
    newConfig.network_name = "after"

    do {
        try store.migrateSecret(from: oldConfig, to: newConfig)
        Issue.record("migration should fail when Data Protection Keychain entitlement is missing")
    } catch NetworkSecretStoreError.missingEntitlement {
        // Expected: a legacy update must not hide invalid signing.
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(keychain.updateQueries.count == 1)
    #expect(keychain.updateQueries[0][kSecUseDataProtectionKeychain as String] as? Bool == true)
}

@Test func failedLegacyMigrationKeepsTheLegacyItem() throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.copyResults = [
        (errSecItemNotFound, nil),
        (errSecSuccess, Data("legacy-secret".utf8) as CFData),
    ]
    keychain.updateResults = [errSecItemNotFound]
    keychain.addResults = [errSecMissingEntitlement]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let config = NetworkConfig(instance_id: "legacy-failure-id", network_name: "office")

    do {
        _ = try store.secret(for: config, reason: "Migrate legacy secret")
        Issue.record("legacy migration should fail when the protected item cannot be created")
    } catch NetworkSecretStoreError.missingEntitlement {
        // Expected.
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(keychain.deleteQueries.isEmpty)
    #expect(keychain.copyQueries[0][kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(keychain.copyQueries[1][kSecUseDataProtectionKeychain as String] == nil)
}

@Test func successfulLegacyMigrationDeletesOnlyTheLegacyItem() throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.copyResults = [
        (errSecItemNotFound, nil),
        (errSecSuccess, Data("legacy-secret".utf8) as CFData),
    ]
    keychain.updateResults = [errSecItemNotFound]
    keychain.addResults = [errSecSuccess]
    keychain.deleteResults = [errSecSuccess]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let config = NetworkConfig(instance_id: "legacy-success-id", network_name: "office")

    #expect(try store.secret(for: config, reason: "Migrate legacy secret") == "legacy-secret")

    let modernContext = try #require(
        keychain.copyQueries[0][kSecUseAuthenticationContext as String] as? LAContext
    )
    let legacyContext = try #require(
        keychain.copyQueries[1][kSecUseAuthenticationContext as String] as? LAContext
    )
    let cleanupContext = try #require(
        keychain.deleteQueries[0][kSecUseAuthenticationContext as String] as? LAContext
    )
    #expect(modernContext === legacyContext)
    #expect(modernContext === cleanupContext)
    #expect(keychain.addQueries.count == 1)
    #expect(keychain.deleteQueries.count == 1)
    #expect(keychain.deleteQueries[0][kSecUseDataProtectionKeychain as String] == nil)
}

private final class RecordingNetworkSecretKeychainClient: NetworkSecretKeychainClient {
    var addResults: [OSStatus] = []
    var updateResults: [OSStatus] = []
    var copyResults: [(OSStatus, CFTypeRef?)] = []
    var deleteResults: [OSStatus] = []

    private(set) var addQueries: [[String: Any]] = []
    private(set) var updateQueries: [[String: Any]] = []
    private(set) var updateAttributes: [[String: Any]] = []
    private(set) var copyQueries: [[String: Any]] = []
    private(set) var deleteQueries: [[String: Any]] = []

    func add(_ attributes: [String: Any]) -> OSStatus {
        addQueries.append(attributes)
        return addResults.isEmpty ? errSecSuccess : addResults.removeFirst()
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updateQueries.append(query)
        updateAttributes.append(attributes)
        return updateResults.isEmpty ? errSecItemNotFound : updateResults.removeFirst()
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?) {
        copyQueries.append(query)
        guard !copyResults.isEmpty else { return (errSecItemNotFound, nil) }
        let result = copyResults.removeFirst()
        return (result.0, result.1)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        deleteQueries.append(query)
        return deleteResults.isEmpty ? errSecItemNotFound : deleteResults.removeFirst()
    }
}
