import Foundation
import Testing
@testable import EasyTierShared

@Test func applicationDatabaseCreatesDefaultWorkspaceAndRoundTripsBusinessData() async throws {
    let directory = try temporaryDatabaseDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = DatabaseTestNetworkSecretStore()
    let database = ApplicationDatabase(
        baseDirectory: directory,
        gatewayFileURL: directory.appending(path: "gateway/config.json"),
        networkSecretStore: secrets
    )

    let initial = try await database.loadWorkspace()
    #expect(initial.configs.count == 1)
    #expect(initial.selectedConfigID == initial.configs.first?.id)

    var first = NetworkConfig(instance_id: "first-id", hostname: "first-host", network_name: "first")
    first.listener_urls = ["tcp://0.0.0.0:11010"]
    let second = NetworkConfig(instance_id: "second-id", hostname: "second-host", network_name: "second")
    let intent = RuntimeIntent(
        target: RuntimeIntentTarget(
            networkName: first.network_name,
            instanceID: first.instance_id,
            recentHostname: "old-host",
            isLocal: true
        ),
        desiredHostname: "new-host",
        baseHostname: "old-host",
        status: .pending,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let subscription = PeerSubscription(
        id: "subscription-id",
        name: "Primary",
        subscriptionURL: URL(string: "https://example.com/peers.json"),
        cards: [
            PeerCard(
                id: "card-id",
                name: "Edge",
                proto: "tcp, udp",
                urls: ["tcp://edge.example.com:11010", "udp://edge.example.com:11010"],
                note: "Preferred"
            )
        ],
        lastFetchedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    let expected = WorkspacePersistenceState(
        configs: [first, second],
        selectedConfigID: second.id,
        mode: .default,
        vpnOnDemandEnabled: true,
        runtimeIntents: [intent],
        reversedPortForwardFingerprints: [first.id: ["fingerprint"]],
        magicDNSSettings: try MagicDNSSettings(dnsSuffix: "database.internal"),
        peerSubscriptions: [subscription]
    )

    try await database.saveWorkspace(expected)

    let loaded = try await database.loadWorkspace()
    #expect(loaded.configs.map(\.id) == expected.configs.map(\.id))
    #expect(loaded.configs.map(\.network_name) == expected.configs.map(\.network_name))
    #expect(loaded.configs.map(\.hostname) == expected.configs.map(\.hostname))
    #expect(loaded.configs.map(\.listener_urls) == expected.configs.map(\.listener_urls))
    #expect(loaded.selectedConfigID == expected.selectedConfigID)
    #expect(loaded.mode == expected.mode)
    #expect(loaded.vpnOnDemandEnabled == expected.vpnOnDemandEnabled)
    #expect(loaded.runtimeIntents == expected.runtimeIntents)
    #expect(loaded.reversedPortForwardFingerprints == expected.reversedPortForwardFingerprints)
    #expect(loaded.magicDNSSettings == expected.magicDNSSettings)
    #expect(loaded.peerSubscriptions == expected.peerSubscriptions)
    #expect(try await database.loadGateway() == nil)

    let gateway = GatewayPersistedState(
        configurationID: "77777777-7777-7777-7777-777777777777",
        revision: 4,
        gatewayEnabled: true
    )
    try await database.saveGateway(gateway)
    #expect(try await database.loadGateway() == gateway)
}

@Test func legacyImportReadsOnlyReferencedTOMLsMovesSecretsAndPreservesLegacyBytes() async throws {
    let directory = try temporaryDatabaseDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = EasyTierStorage(baseDirectory: directory)
    let referenced = NetworkConfig(
        instance_id: "referenced-id",
        network_name: "referenced",
        network_secret: "legacy-secret"
    )
    try storage.save(
        AppSnapshot(configIDs: [referenced.id], lastSelectedConfigID: referenced.id),
        configs: [referenced]
    )
    let stateURL = directory.appending(path: "state.json")
    let referencedURL = storage.configURL(forID: referenced.id)
    let orphanURL = storage.configURL(forID: "orphan-id")
    let orphanData = Data("instance_name = \"orphan-id\"\nnetwork_name = \"orphan\"\n".utf8)
    try orphanData.write(to: orphanURL)
    let originalState = try Data(contentsOf: stateURL)
    let originalReferenced = try Data(contentsOf: referencedURL)
    let secrets = DatabaseTestNetworkSecretStore()
    let database = ApplicationDatabase(
        baseDirectory: directory,
        gatewayFileURL: directory.appending(path: "gateway/config.json"),
        networkSecretStore: secrets
    )

    let imported = try await database.loadWorkspace()

    #expect(imported.configs.map(\.id) == [referenced.id])
    #expect(imported.configs.first?.network_secret == nil)
    #expect(await secrets.savedSecret(for: referenced.network_name) == "legacy-secret")
    #expect(try Data(contentsOf: stateURL) == originalState)
    #expect(try Data(contentsOf: referencedURL) == originalReferenced)
    #expect(try Data(contentsOf: orphanURL) == orphanData)
    let databaseBytes = try Data(contentsOf: directory.appending(path: "easytier.sqlite3"))
    #expect(databaseBytes.range(of: Data("legacy-secret".utf8)) == nil)
}

@Test func failedLegacyImportIsRetryableAndExplicitRebuildSkipsBadLegacyData() async throws {
    let directory = try temporaryDatabaseDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = EasyTierStorage(baseDirectory: directory)
    let config = NetworkConfig(instance_id: "broken-id", network_name: "broken")
    try storage.save(
        AppSnapshot(configIDs: [config.id], lastSelectedConfigID: config.id),
        configs: [config]
    )
    let stateURL = directory.appending(path: "state.json")
    let configURL = storage.configURL(forID: config.id)
    let originalState = try Data(contentsOf: stateURL)
    try Data("invalid = [".utf8).write(to: configURL)
    let originalConfig = try Data(contentsOf: configURL)
    let database = ApplicationDatabase(
        baseDirectory: directory,
        gatewayFileURL: directory.appending(path: "gateway/config.json"),
        networkSecretStore: DatabaseTestNetworkSecretStore()
    )

    await #expect(throws: (any Error).self) {
        _ = try await database.loadWorkspace()
    }
    await #expect(throws: (any Error).self) {
        try await database.retryPreparation()
    }
    #expect(try Data(contentsOf: stateURL) == originalState)
    #expect(try Data(contentsOf: configURL) == originalConfig)

    try await database.rebuildEmptyDatabase()
    let rebuilt = try await database.loadWorkspace()
    #expect(rebuilt.configs.count == 1)
    #expect(rebuilt.selectedConfigID == rebuilt.configs.first?.id)
    #expect(try Data(contentsOf: stateURL) == originalState)
    #expect(try Data(contentsOf: configURL) == originalConfig)

    let recoveryRoot = directory.appending(path: "database-recovery")
    let recoveryDirectories = try FileManager.default.contentsOfDirectory(
        at: recoveryRoot,
        includingPropertiesForKeys: nil
    )
    #expect(recoveryDirectories.count == 1)
    let recoveredDatabase = recoveryDirectories[0].appending(path: "easytier.sqlite3")
    #expect(FileManager.default.fileExists(atPath: recoveredDatabase.path))
}

private func temporaryDatabaseDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "application-database-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private final class DatabaseTestNetworkSecretStore: NetworkSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func save(
        _ secret: String,
        for config: NetworkConfig,
        purpose _: NetworkSecretAccessPurpose
    ) async throws {
        lock.withLock {
            secrets[config.network_name] = secret
        }
    }

    func secret(
        for config: NetworkConfig,
        purpose _: NetworkSecretAccessPurpose,
        reason _: String?
    ) async throws -> String? {
        lock.withLock { secrets[config.network_name] }
    }

    func deleteSecret(
        for config: NetworkConfig,
        purpose _: NetworkSecretAccessPurpose
    ) async throws {
        _ = lock.withLock {
            secrets.removeValue(forKey: config.network_name)
        }
    }

    func presence(for config: NetworkConfig) async throws -> NetworkSecretPresence {
        lock.withLock { secrets[config.network_name] == nil ? .missing : .present }
    }

    func authenticationCapability() -> NetworkSecretAuthenticationCapability { .unknown }

    func invalidateAuthenticationSession() {}

    func savedSecret(for networkName: String) async -> String? {
        lock.withLock { secrets[networkName] }
    }
}
