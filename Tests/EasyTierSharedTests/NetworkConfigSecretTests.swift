import Foundation
import LocalAuthentication
import Testing
@testable import EasyTierShared

@MainActor
@Test func explicitNetworkSecretReadReportsErrors() async {
    let config = NetworkConfig(instance_id: "explicit-error-id", network_name: "office")
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    secrets.readError = EasyTierCoreError.operationFailed("keychain failed")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    do {
        _ = try await store.revealNetworkSecret(for: config)
        Issue.record("explicit read should throw")
    } catch {
        #expect(error.localizedDescription.contains("keychain failed"))
    }
}

@MainActor
@Test func sequentialSecretReadsDoNotRetainAPlaintextAppStoreCache() async {
    let config = NetworkConfig(instance_id: "cache-id", network_name: "office")
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "cached-secret"])
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    _ = try? await store.revealNetworkSecret(for: config)
    #expect(secrets.readReasons.count == 1)

    _ = try? await store.revealNetworkSecret(for: config)
    #expect(secrets.readReasons.count == 2, "LAContext, not the plaintext secret, owns authentication reuse")
}

@MainActor
@Test func concurrentSecretReadsUseIndependentAuthenticationActions() async throws {
    let config = NetworkConfig(instance_id: "concurrent-secret-id", network_name: "office")
    let secrets = BlockingNetworkSecretStore(secret: "shared-secret")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    let first = Task { try await store.revealNetworkSecret(for: config) }
    let second = Task { try await store.revealNetworkSecret(for: config) }
    defer { secrets.releaseReads() }

    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while secrets.readCount < 2, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    try? await Task.sleep(for: .milliseconds(50))

    #expect(secrets.readCount == 2, "each user action must own its own Keychain authentication")

    secrets.releaseReads()
    #expect(try await first.value == "shared-secret")
    #expect(try await second.value == "shared-secret")
}

@MainActor
@Test func systemSleepInvalidatesNetworkSecretAuthenticationSession() {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    store.handleSystemWillSleep(now: Date(timeIntervalSince1970: 100))

    #expect(secrets.authenticationInvalidationCount == 1)
    #expect(store.networkSecretSessionRevision == 1)
}

@MainActor
@Test func selectingAnotherNetworkInvalidatesNetworkSecretSession() {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    let first = NetworkConfig(instance_id: "first-secret-session-id", network_name: "office")
    let second = NetworkConfig(instance_id: "second-secret-session-id", network_name: "lab")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [first, second]

    store.selectedConfigID = first.instance_id
    #expect(store.networkSecretSessionRevision == 0)

    store.selectedConfigID = second.instance_id

    #expect(secrets.authenticationInvalidationCount == 1)
    #expect(store.networkSecretSessionRevision == 1)
}

@MainActor
@Test func workspaceSessionResignInvalidatesNetworkSecretAuthenticationSession() {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    store.handleUserSessionDidResignActive()

    #expect(secrets.authenticationInvalidationCount == 1)
    #expect(store.networkSecretSessionRevision == 1)
}

@MainActor
@Test func canceledNetworkSecretReadDoesNotSurfaceGlobalError() async {
    let config = NetworkConfig(instance_id: "canceled-secret-id", network_name: "office")
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    secrets.readError = NetworkSecretStoreError.keychain(errSecUserCanceled)
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()

    #expect(store.lastError == nil)
}

@MainActor
@Test func applicationFocusLossPreservesAuthenticationAndDraftRevision() {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    store.handleApplicationDidResignActive()

    #expect(secrets.authenticationInvalidationCount == 0)
    #expect(store.networkSecretSessionRevision == 0)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func wakeRecoveryWaitsUntilTheApplicationIsActive() async {
    let client = RecordingToggleClient()
    let controller = RuntimeSessionController(
        runtimeClient: client,
        helperRegistration: nil,
        systemSleepPreventer: RecordingSystemSleepPreventer(),
        wakeRecoveryDelay: .milliseconds(10)
    )
    var recoveryCount = 0
    var wakeContinuation: AsyncStream<Void>.Continuation?
    let wakeEvents = AsyncStream<Void> { wakeContinuation = $0 }
    controller.startPolling(
        refresh: {},
        handleWillSleep: {},
        handleSessionResign: {},
        handleDidWake: {
            recoveryCount += 1
            wakeContinuation?.yield()
            wakeContinuation?.finish()
        }
    )
    defer { controller.stopPolling() }

    controller.setApplicationActive(false)
    controller.handleSystemDidWakeNotification()
    #expect(recoveryCount == 0)

    controller.setApplicationActive(true)
    for await _ in wakeEvents { break }
    #expect(recoveryCount == 1)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func wakeRecoveryWaitsUntilTheUserSessionIsActive() async {
    let client = RecordingToggleClient()
    let controller = RuntimeSessionController(
        runtimeClient: client,
        helperRegistration: nil,
        systemSleepPreventer: RecordingSystemSleepPreventer(),
        wakeRecoveryDelay: .milliseconds(10)
    )
    var recoveryCount = 0
    var wakeContinuation: AsyncStream<Void>.Continuation?
    let wakeEvents = AsyncStream<Void> { wakeContinuation = $0 }
    controller.startPolling(
        refresh: {},
        handleWillSleep: {},
        handleSessionResign: {},
        handleDidWake: {
            recoveryCount += 1
            wakeContinuation?.yield()
            wakeContinuation?.finish()
        }
    )
    defer { controller.stopPolling() }

    controller.handleUserSessionDidResignActiveNotification()
    controller.handleSystemDidWakeNotification()
    #expect(recoveryCount == 0)

    controller.handleUserSessionDidBecomeActiveNotification()
    for await _ in wakeEvents { break }
    #expect(recoveryCount == 1)
}

@MainActor
@Test func importTOMLMigratesNetworkSecretToKeychain() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let secrets = MemoryNetworkSecretStore()
    let config = NetworkConfig(instance_id: "import-id", network_name: "office", network_secret: "import-secret")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        storage: storage,
        networkSecretStore: secrets
    )

    await store.importTOML(try NetworkConfigTOMLCodec.encode(config))

    let databaseData = try Data(contentsOf: directory.appending(path: "easytier.sqlite3"))

    #expect(secrets.secrets["office"] == "import-secret")
    #expect(!databaseData.contains(Data("import-secret".utf8)))
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "configs/import-id.toml").path))
    #expect(store.configs.first?.network_secret?.nilIfEmpty == nil)
}

@MainActor
@Test func importTOMLSurfacesReadableParserErrors() async {
    let store = EasyTierAppStore()

    await store.importTOML(#"instance_name = "broken"#)

    #expect(store.lastError?.contains("Invalid TOML syntax at line") == true)
}

@MainActor
@Test func importTOMLReportsInvalidCharacterAtParserErrorLocation() async {
    let store = EasyTierAppStore()

    await store.importTOML("instance_name = \u{201C}broken\"")

    #expect(store.lastError?.contains("Character at line 1, column 17") == true)
    #expect(store.lastError?.contains("U+201C") == true)
}

@MainActor
@Test func deleteSelectedConfigRemovesTheLastSharedKeychainSecret() async {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    let config = NetworkConfig(instance_id: "delete-id", network_name: "office")
    let store = EasyTierAppStore(client: RecordingToggleClient(), networkSecretStore: secrets)

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.deleteSelectedConfig()

    #expect(secrets.secrets["office"] == nil)
}

@MainActor
@Test func deleteSelectedConfigAlwaysDeletesItsUUIDScopedSecret() async {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    let first = NetworkConfig(instance_id: "delete-shared-first", network_name: "office")
    let second = NetworkConfig(instance_id: "delete-shared-second", network_name: "office")
    let store = EasyTierAppStore(client: RecordingToggleClient(), networkSecretStore: secrets)
    store.configs = [first, second]
    store.selectedConfigID = first.instance_id

    await store.deleteSelectedConfig()

    #expect(secrets.secrets["office"] == nil)
    #expect(store.configs.map(\.id) == [second.id])
}

@MainActor
@Test func canceledKeychainAuthorizationLeavesTheNetworkWithoutShowingAnError() async {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    secrets.deleteError = NetworkSecretStoreError.authentication(LAError.Code.appCancel.rawValue)
    let config = NetworkConfig(instance_id: "delete-app-cancel-id", network_name: "office")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [config]
    store.selectedConfigID = config.id

    await store.deleteSelectedConfig()

    #expect(store.configs == [config])
    #expect(store.selectedConfigID == config.id)
    #expect(store.lastError == nil)
}

@MainActor
@Test func keychainNetworkSecretsRemainIndependentAcrossConfigurations() async throws {
    let secrets = MemoryNetworkSecretStore()
    let first = NetworkConfig(instance_id: "first-id", network_name: "office", network_secret: "office-secret")
    let second = NetworkConfig(instance_id: "second-id", network_name: "lab", network_secret: "lab-secret")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    try await store.saveNetworkSecretToKeychain("office-secret", for: first)
    try await store.saveNetworkSecretToKeychain("lab-secret", for: second)
    store.configs = [first, second].map {
        var config = $0
        config.network_secret = nil
        return config
    }
    await store.save()

    #expect(secrets.secrets["office"] == "office-secret")
    #expect(secrets.secrets["lab"] == "lab-secret")
}

@MainActor
@Test func updateConfigDoesNotMoveKeychainSecretWhenNetworkNameChanges() async throws {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "office-secret"])
    let original = NetworkConfig(instance_id: "rename-id", network_name: "office")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    store.configs = [original]
    store.selectedConfigID = original.instance_id

    var updated = original
    updated.network_name = "renamed"
    try await store.updateConfig(id: original.instance_id, with: updated, saveImmediately: true)

    #expect(secrets.secrets["office"] == "office-secret")
    #expect(secrets.secrets["renamed"] == nil)
}

@Test func incompatibleStateIsResetWithoutBackupAndTomlFilesArePreserved() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let config = NetworkConfig(instance_id: "legacy-id", network_name: "legacy")
    let configURL = directory.appendingPathComponent("configs/legacy-id.toml")
    try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try NetworkConfigTOMLCodec.encode(config).write(to: configURL, atomically: true, encoding: .utf8)
    let state = """
    {
      "configs" : [
        {
          "id" : "legacy-id",
          "source" : "user",
          "tomlPath" : "configs/legacy-id.toml"
        }
      ],
      "lastSelectedConfigID" : "legacy-id"
    }
    """
    try state.write(to: directory.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)

    let loaded = try storage.load()

    #expect(loaded.recoveryMessage?.contains("reset") == true)
    #expect(loaded.configs.count == 1)
    #expect(loaded.configs.first?.instance_id != config.instance_id)
    #expect(FileManager.default.fileExists(atPath: configURL.path))
    let backupNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!backupNames.contains { $0.hasPrefix("state.incompatible-") && $0.hasSuffix(".json") })
}

@Test func currentSchemaConfigFailureDoesNotResetState() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let config = NetworkConfig(instance_id: "current-id", network_name: "current")
    let snapshot = AppSnapshot(configIDs: [config.id], lastSelectedConfigID: config.id)
    try storage.save(snapshot, configs: [config])

    let stateURL = directory.appendingPathComponent("state.json")
    let originalState = try Data(contentsOf: stateURL)
    try "invalid = [".write(to: storage.configURL(forID: config.id), atomically: true, encoding: .utf8)

    do {
        _ = try storage.load()
        Issue.record("A current-schema state with invalid TOML should surface the config error.")
    } catch {}

    #expect(try Data(contentsOf: stateURL) == originalState)
    let backupNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!backupNames.contains { $0.hasPrefix("state.incompatible-") && $0.hasSuffix(".json") })
}

@Test func runtimeIntentsRoundTripThroughStateJson() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let config = NetworkConfig(instance_id: "lab-id", network_name: "lab")
    let intent = RuntimeIntent(
        target: RuntimeIntentTarget(
            networkName: "lab",
            instanceID: "remote-id",
            peerID: "200",
            recentHostname: "old-host",
            recentIPv4: "10.126.126.8",
            isLocal: false
        ),
        desiredHostname: "new-host",
        baseHostname: "old-host",
        status: .pending
    )
    let snapshot = AppSnapshot(
        configIDs: [config.id],
        mode: .default,
        lastSelectedConfigID: config.instance_id,
        runtimeIntents: [intent]
    )

    try storage.save(snapshot, configs: [config])
    let loaded = try storage.load()

    #expect(loaded.snapshot.runtimeIntents.count == 1)
    #expect(loaded.snapshot.runtimeIntents.first?.target.instanceID == "remote-id")
    #expect(loaded.snapshot.runtimeIntents.first?.desiredHostname == "new-host")
    #expect(loaded.snapshot.runtimeIntents.first?.baseHostname == "old-host")
    #expect(loaded.snapshot.runtimeIntents.first?.status == .pending)
}

@Test func defaultStorageUsesBundleSpecificAppSupportDirectory() {
    #expect(EasyTierStorage.default.baseDirectory.lastPathComponent == "com.kkrainbow.easytier.mac")
}

@Test func testStoreStorageIsIsolatedFromApplicationSupport() {
    let storage = EasyTierStorage.isolatedForTesting()

    #expect(storage.baseDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    #expect(storage.baseDirectory.lastPathComponent != "com.kkrainbow.easytier.mac")
}

@MainActor
@Test func selectedConfigDoesNotFallBackToFirstConfigWhenSelectionIsCleared() {
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    let store = EasyTierAppStore(client: RecordingToggleClient())

    store.configs = [first, second]
    store.selectedConfigID = nil
    store.instances = [NetworkInstance(instance_id: first.instance_id, name: first.network_name, running: true)]

    #expect(store.selectedConfig == nil)
    #expect(store.selectedRunningInstance == nil)
    #expect(!store.selectedConfigIsRunning)
}

@MainActor
@Test func clearedSelectionIsNotOverriddenByRuntimeManagedNetworkWhenLocalConfigsExist() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    let local = NetworkConfig(instance_id: "local-id", network_name: "local-network")
    store.configs = [local]
    store.selectedConfigID = nil

    client.networkInfos = [
        "managed-network": NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "managed-mac", peer_id: 7),
            running: true,
            instance_id: "managed-id"
        ),
    ]
    await store.refreshRuntime()

    #expect(store.runtimeManagedConfigs.map(\.id) == ["managed-id"])
    #expect(store.selectedConfigID == nil)
    #expect(store.selectedConfig == nil)
}
