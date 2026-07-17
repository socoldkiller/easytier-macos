import Foundation
import LocalAuthentication
import Security
import Testing
@testable import EasyTierShared

@Test func saveUsesExplicitBackendsAndVerifiesBeforeCleanup() async throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.updateResults = [errSecSuccess]
    keychain.copyResults = [(errSecSuccess, nil)]
    keychain.deleteResults = [errSecSuccess]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let config = NetworkConfig(instance_id: "explicit-backend-id", network_name: "office")

    let result = try await store.save("secret", for: config)

    #expect(result.cleanup == .completed)
    #expect(keychain.updateQueries.count == 1)
    #expect(keychain.copyQueries.count == 1)
    #expect(keychain.deleteQueries.count == 1)
    #expect(keychain.updateQueries[0][kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(keychain.copyQueries[0][kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(keychain.deleteQueries[0][kSecUseDataProtectionKeychain as String] as? Bool == false)
    #expect(keychain.allQueries.allSatisfy {
        $0[kSecUseDataProtectionKeychain as String] is Bool
            && $0[kSecAttrSynchronizable as String] as? Bool == false
    })
}

@Test func missingEntitlementNeverFallsBackToAnUnprotectedItem() async {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.updateResults = [errSecItemNotFound]
    keychain.addResults = [errSecMissingEntitlement]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let config = NetworkConfig(instance_id: "missing-entitlement-id", network_name: "office")

    do {
        _ = try await store.save("secret", for: config)
        Issue.record("save should fail when the protected item cannot be added")
    } catch NetworkSecretStoreError.missingEntitlement {
        // Expected.
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(keychain.addQueries.count == 1)
    #expect(keychain.addQueries[0][kSecAttrAccessControl as String] != nil)
    #expect(keychain.addQueries[0][kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(keychain.deleteQueries.isEmpty)
}

@Test func duplicateAddRetriesTheProtectedUpdate() async throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.updateResults = [errSecItemNotFound, errSecSuccess]
    keychain.addResults = [errSecDuplicateItem]
    keychain.copyResults = [(errSecSuccess, nil)]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let config = NetworkConfig(instance_id: "duplicate-id", network_name: "office")

    _ = try await store.save("secret", for: config)

    #expect(keychain.updateQueries.count == 2)
    #expect(keychain.addQueries.count == 1)
    #expect(keychain.updateQueries.allSatisfy {
        $0[kSecUseDataProtectionKeychain as String] as? Bool == true
    })
}

@Test func failedVerificationLeavesTheLegacyItemUntouched() async {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.updateResults = [errSecSuccess]
    keychain.copyResults = [
        (errSecItemNotFound, nil),
        (errSecItemNotFound, nil),
    ]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let config = NetworkConfig(instance_id: "verification-id", network_name: "office")

    do {
        _ = try await store.save("secret", for: config)
        Issue.record("save should fail when the modern item cannot be verified")
    } catch NetworkSecretStoreError.verificationFailed {
        // Expected.
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(keychain.deleteQueries.isEmpty)
}

@Test func protectedVerificationUsesANonInteractiveAuthenticatedFallback() async throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.updateResults = [errSecSuccess]
    keychain.copyResults = [
        (errSecItemNotFound, nil),
        (errSecInteractionNotAllowed, nil),
    ]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let config = NetworkConfig(instance_id: "protected-verification-id", network_name: "office")

    _ = try await store.save("secret", for: config)

    #expect(keychain.copyQueries.count == 2)
    #expect(keychain.copyQueries[0][kSecReturnAttributes as String] as? Bool == true)
    #expect(
        keychain.copyQueries[0][kSecUseAuthenticationUI as String] as? String
            == kSecUseAuthenticationUISkip as String
    )
    #expect(keychain.copyQueries[1][kSecReturnData as String] as? Bool == true)
    #expect(keychain.copyQueries[1][kSecUseAuthenticationUI as String] == nil)
    let context = try #require(
        keychain.copyQueries[1][kSecUseAuthenticationContext as String] as? LAContext
    )
    #expect(context.touchIDAuthenticationAllowableReuseDuration == 0)
    #expect(keychain.copyContextInteractionBlocked == [true])
}

@Test func legacyCleanupFailureDoesNotUndoAVerifiedModernWrite() async throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.updateResults = [errSecSuccess]
    keychain.copyResults = [(errSecSuccess, nil)]
    keychain.deleteResults = [errSecAuthFailed]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let config = NetworkConfig(instance_id: "cleanup-id", network_name: "office")

    let result = try await store.save("secret", for: config)

    #expect(result.cleanup == .pending([
        NetworkSecretCleanupIssue(backend: .legacy, status: errSecAuthFailed),
    ]))
}

@Test func successfulLegacyReadMigratesThenDeletesOnlyTheLegacyItem() async throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.copyResults = [
        (errSecItemNotFound, nil),
        (errSecSuccess, Data("legacy-secret".utf8) as CFData),
        (errSecSuccess, nil),
    ]
    keychain.updateResults = [errSecItemNotFound]
    keychain.addResults = [errSecSuccess]
    keychain.deleteResults = [errSecSuccess]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let config = NetworkConfig(instance_id: "legacy-id", network_name: "office")

    let result = try #require(
        try await store.secret(for: config, purpose: .reveal)
    )

    #expect(result.secret == "legacy-secret")
    #expect(result.cleanup == .completed)
    #expect(keychain.copyQueries[0][kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(keychain.copyQueries[1][kSecUseDataProtectionKeychain as String] as? Bool == false)
    #expect(keychain.addQueries[0][kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(keychain.deleteQueries[0][kSecUseDataProtectionKeychain as String] as? Bool == false)
}

@Test func failedLegacyMigrationKeepsTheLegacyItem() async {
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
        _ = try await store.secret(for: config, purpose: .reveal)
        Issue.record("migration should fail when the protected item cannot be added")
    } catch NetworkSecretStoreError.missingEntitlement {
        // Expected.
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(keychain.deleteQueries.isEmpty)
}

@Test func renameCleanupDoesNotDeleteModernSourceWhenLegacyDeletionFails() async throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.copyResults = [
        (errSecSuccess, nil),
        (errSecItemNotFound, nil),
        (errSecItemNotFound, nil),
        (errSecSuccess, Data("source-secret".utf8) as CFData),
        (errSecSuccess, nil),
    ]
    keychain.updateResults = [errSecItemNotFound]
    keychain.addResults = [errSecSuccess]
    keychain.deleteResults = [
        errSecItemNotFound,
        errSecItemNotFound,
        errSecAuthFailed,
    ]
    let authenticator = RecordingNetworkSecretAuthenticator()
    let store = SystemNetworkSecretStore(keychain: keychain, authenticator: authenticator)
    let oldConfig = NetworkConfig(instance_id: "rename-id", network_name: "before")
    var newConfig = oldConfig
    newConfig.network_name = "after"

    let result = try await store.migrateSecret(
        from: oldConfig,
        to: newConfig,
        removeSource: true
    )

    #expect(result.cleanup.issues.contains {
        $0.backend == .legacy && $0.status == errSecAuthFailed
    })
    #expect(authenticator.authenticationCount == 1)
    #expect(keychain.deleteQueries.count == 3)
    #expect(keychain.deleteQueries.allSatisfy {
        $0[kSecUseDataProtectionKeychain as String] as? Bool == false
    })
}

@Test func everyLogicalReadGetsANewPurposeScopedContext() async throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.copyResults = [
        (errSecSuccess, Data("run".utf8) as CFData),
        (errSecSuccess, Data("reveal".utf8) as CFData),
    ]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let config = NetworkConfig(instance_id: "context-id", network_name: "office")

    _ = try await store.secret(for: config, purpose: .run)
    _ = try await store.secret(for: config, purpose: .reveal)

    let runContext = try #require(
        keychain.copyQueries[0][kSecUseAuthenticationContext as String] as? LAContext
    )
    let revealContext = try #require(
        keychain.copyQueries[1][kSecUseAuthenticationContext as String] as? LAContext
    )
    #expect(runContext !== revealContext)
    #expect(keychain.copyContextReuseDurations == [10, 0])
}

@Test func presenceChecksNeverPresentAuthenticationUI() async throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.copyResults = [
        (errSecItemNotFound, nil),
        (errSecInteractionNotAllowed, nil),
        (errSecItemNotFound, nil),
    ]
    let store = SystemNetworkSecretStore(keychain: keychain)
    let config = NetworkConfig(instance_id: "presence-id", network_name: "office")

    #expect(try await store.presence(for: config) == .interactionRequired)
    #expect(keychain.copyQueries.count == 3)
    #expect(keychain.copyQueries[0][kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(keychain.copyQueries[1][kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(keychain.copyQueries[2][kSecUseDataProtectionKeychain as String] as? Bool == false)
    #expect(keychain.copyQueries[0][kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUISkip as String)
    #expect(keychain.copyQueries[2][kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUISkip as String)
    #expect(keychain.copyQueries[0][kSecUseAuthenticationContext as String] == nil)
    #expect(keychain.copyQueries[2][kSecUseAuthenticationContext as String] == nil)
    #expect(keychain.copyQueries[1][kSecUseAuthenticationUI as String] == nil)
    #expect(keychain.copyQueries[1][kSecReturnData as String] as? Bool == true)
    let context = try #require(
        keychain.copyQueries[1][kSecUseAuthenticationContext as String] as? LAContext
    )
    #expect(context.touchIDAuthenticationAllowableReuseDuration == 0)
    #expect(keychain.copyContextInteractionBlocked == [true])
}

@Test func deleteAuthenticatesFreshAndDeletesLegacyBeforeModern() async throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.copyResults = [(errSecSuccess, nil)]
    keychain.deleteResults = [errSecSuccess, errSecSuccess]
    let authenticator = RecordingNetworkSecretAuthenticator()
    let store = SystemNetworkSecretStore(keychain: keychain, authenticator: authenticator)
    let config = NetworkConfig(instance_id: "delete-id", network_name: "office")

    try await store.deleteSecret(for: config, purpose: .delete)

    #expect(authenticator.authenticationCount == 1)
    #expect(keychain.deleteQueries.count == 2)
    #expect(keychain.deleteQueries[0][kSecUseDataProtectionKeychain as String] as? Bool == false)
    #expect(keychain.deleteQueries[1][kSecUseDataProtectionKeychain as String] as? Bool == true)
    let context = try #require(
        keychain.deleteQueries[0][kSecUseAuthenticationContext as String] as? LAContext
    )
    #expect(context.touchIDAuthenticationAllowableReuseDuration == 0)
}

@Test func failedDeleteAuthenticationDoesNotTouchEitherKeychain() async {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.copyResults = [(errSecSuccess, nil)]
    let authenticator = RecordingNetworkSecretAuthenticator(
        error: NetworkSecretStoreError.authentication(LAError.Code.userCancel.rawValue)
    )
    let store = SystemNetworkSecretStore(keychain: keychain, authenticator: authenticator)
    let config = NetworkConfig(instance_id: "delete-cancel-id", network_name: "office")

    do {
        try await store.deleteSecret(for: config, purpose: .delete)
        Issue.record("delete should stop after canceled authentication")
    } catch let error as NetworkSecretStoreError {
        #expect(error.isUserCancellation)
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(keychain.deleteQueries.isEmpty)
}

@Test func accessGroupAndTestNamespaceAreAppliedToEveryQuery() async throws {
    let keychain = RecordingNetworkSecretKeychainClient()
    keychain.updateResults = [errSecSuccess]
    keychain.copyResults = [(errSecSuccess, nil)]
    let namespace = NetworkSecretKeychainNamespace(
        service: "test.service.\(UUID().uuidString)",
        accessGroup: "TEAM.test.group",
        accountPrefix: "test-"
    )
    let store = SystemNetworkSecretStore(keychain: keychain, namespace: namespace)
    let config = NetworkConfig(instance_id: "namespace-id", network_name: " office ")

    _ = try await store.save("secret", for: config)

    #expect(keychain.allQueries.allSatisfy {
        $0[kSecAttrService as String] as? String == namespace.service
            && $0[kSecAttrAccessGroup as String] as? String == namespace.accessGroup
    })
    #expect(keychain.updateQueries[0][kSecAttrAccount as String] as? String == "test-office")
}

@Test func keychainAndAuthenticationCancellationErrorsAreRecognized() {
    #expect(NetworkSecretStoreError.keychain(errSecUserCanceled).isUserCancellation)
    #expect(NetworkSecretStoreError.authentication(LAError.Code.userCancel.rawValue).isUserCancellation)
    #expect(!NetworkSecretStoreError.keychain(errSecAuthFailed).isUserCancellation)
    #expect(!NetworkSecretStoreError.invalidData.isUserCancellation)
}

private final class RecordingNetworkSecretAuthenticator: NetworkSecretAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private let error: Error?
    private var storedAuthenticationCount = 0

    init(error: Error? = nil) {
        self.error = error
    }

    var authenticationCount: Int {
        lock.withLock { storedAuthenticationCount }
    }

    func authenticate(context _: LAContext, reason _: String) async throws {
        lock.withLock { storedAuthenticationCount += 1 }
        if let error { throw error }
    }
}

private final class RecordingNetworkSecretKeychainClient: NetworkSecretKeychainClient, @unchecked Sendable {
    var addResults: [OSStatus] = []
    var updateResults: [OSStatus] = []
    var copyResults: [(OSStatus, CFTypeRef?)] = []
    var deleteResults: [OSStatus] = []

    private(set) var addQueries: [[String: Any]] = []
    private(set) var updateQueries: [[String: Any]] = []
    private(set) var updateAttributes: [[String: Any]] = []
    private(set) var copyQueries: [[String: Any]] = []
    private(set) var copyContextReuseDurations: [TimeInterval] = []
    private(set) var copyContextInteractionBlocked: [Bool] = []
    private(set) var deleteQueries: [[String: Any]] = []

    var allQueries: [[String: Any]] {
        addQueries + updateQueries + copyQueries + deleteQueries
    }

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
        if let context = query[kSecUseAuthenticationContext as String] as? LAContext {
            copyContextReuseDurations.append(context.touchIDAuthenticationAllowableReuseDuration)
            copyContextInteractionBlocked.append(context.interactionNotAllowed)
        }
        guard !copyResults.isEmpty else { return (errSecItemNotFound, nil) }
        let result = copyResults.removeFirst()
        return (result.0, result.1)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        deleteQueries.append(query)
        return deleteResults.isEmpty ? errSecItemNotFound : deleteResults.removeFirst()
    }
}
