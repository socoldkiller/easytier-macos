import Foundation
import Testing
@testable import EasyTierShared

@MainActor
@Test func appQuitStopsNetworkAndShutdownsHelperWhenVpnOnDemandIsOff() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "quit-id", network_name: "office")
    let store = EasyTierAppStore(client: client)

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)]

    await store.prepareForAppQuit()

    #expect(client.retainedInstanceNames == [[]])
    #expect(client.shutdownCount == 1)
}

@MainActor
@Test func appQuitLeavesNetworkAndHelperRunningWhenVpnOnDemandIsOn() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "quit-ondemand-id", network_name: "office")
    let store = EasyTierAppStore(client: client)

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)]
    store.vpnOnDemandEnabled = true

    await store.prepareForAppQuit()

    #expect(client.retainedInstanceNames.isEmpty)
    #expect(client.shutdownCount == 0)
}

@MainActor
@Test func appQuitLeavesNoTunNetworkRunningWhenVpnOnDemandIsOn() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "quit-notun-id", network_name: "office", no_tun: true)
    let store = EasyTierAppStore(client: client)

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)]
    store.vpnOnDemandEnabled = true

    await store.prepareForAppQuit()

    #expect(client.stoppedInstanceNames.isEmpty)
    #expect(client.retainedInstanceNames.isEmpty)
    #expect(client.shutdownCount == 0)
}

@MainActor
@Test func noTunNetworkStillRequiresAndUsesTheRuntimeHelper() async {
    let client = RecordingToggleClient()
    let backend = HelperRegistrationBackendSpy(status: .enabled)
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)
    let config = NetworkConfig(instance_id: "helper-no-tun-id", network_name: "helper-no-tun", no_tun: true)
    let store = EasyTierAppStore(
        runtimeClient: client,
        helperRegistration: registration,
        storage: .isolatedForTesting()
    )
    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()

    #expect(backend.probeCount == 1)
    #expect(client.configuredRPCPortals == [AppMode.default.rpcPortal])
    #expect(client.runConfigs.map(\.instance_id) == [config.instance_id])
}

@MainActor
@Test func launchPreparationRegistersAndConfiguresTheRuntimeHelperOnce() async {
    let client = RecordingToggleClient()
    let backend = HelperRegistrationBackendSpy(status: .notRegistered)
    backend.statusAfterRegister = .enabled
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)
    let store = EasyTierAppStore(
        runtimeClient: client,
        helperRegistration: registration,
        storage: .isolatedForTesting()
    )

    #expect(await store.prepareRuntimeServiceAfterLaunch())
    #expect(await store.prepareRuntimeServiceAfterLaunch())

    #expect(backend.registerCount == 1)
    #expect(backend.probeCount == 2)
    #expect(client.configuredRPCPortals == [AppMode.default.rpcPortal])
}

@MainActor
@Test func softwareUpdateStopsNetworkAndHelperEvenWithVpnOnDemand() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "update-id", network_name: "office")
    let store = EasyTierAppStore(client: client)

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)]
    store.vpnOnDemandEnabled = true

    #expect(store.runningConfigIDsForSoftwareUpdate() == [config.instance_id])

    await store.prepareForSoftwareUpdate()

    #expect(client.retainedInstanceNames == [[]])
    #expect(client.shutdownCount == 1)
    #expect(store.isQuitting)
}

@MainActor
@Test func softwareUpdateRestoreStartsRequestedConfigurationOnce() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "restore-id", network_name: "office", no_tun: true)
    let store = EasyTierAppStore(client: client)

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.restoreConfigsAfterSoftwareUpdate(configIDs: [config.instance_id, "missing-id"])

    #expect(client.runConfigs.map(\.instance_id) == [config.instance_id])
    #expect(!store.isQuitting)
}

@MainActor
@Test func appStoreExplicitlySavesNetworkSecretInKeychainNotToml() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let secrets = MemoryNetworkSecretStore()
    let config = NetworkConfig(instance_id: "secret-id", network_name: "lab", network_secret: "super-secret")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        storage: storage,
        networkSecretStore: secrets
    )

    try await store.saveNetworkSecretToKeychain("super-secret", for: config)
    var persistedConfig = config
    persistedConfig.network_secret = nil
    store.configs = [persistedConfig]
    store.selectedConfigID = config.instance_id
    await store.save()

    let databaseData = try Data(contentsOf: directory.appending(path: "easytier.sqlite3"))

    #expect(secrets.secrets["lab"] == "super-secret")
    #expect(!databaseData.contains(Data("super-secret".utf8)))
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "configs/secret-id.toml").path))
    #expect(store.configs.first?.network_secret?.nilIfEmpty == nil)
}

@MainActor
@Test func genericConfigPersistenceNeverImplicitlyWritesKeychain() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let secrets = MemoryNetworkSecretStore()
    let config = NetworkConfig(
        instance_id: "sanitized-save-id",
        network_name: "office",
        network_secret: "must-not-be-written-implicitly"
    )
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        storage: storage,
        networkSecretStore: secrets
    )
    store.configs = [config]
    store.selectedConfigID = config.id

    await store.save()

    let databaseData = try Data(contentsOf: directory.appending(path: "easytier.sqlite3"))
    #expect(secrets.secrets.isEmpty)
    #expect(!databaseData.contains(Data("must-not-be-written-implicitly".utf8)))
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "configs/sanitized-save-id.toml").path))
    #expect(store.configs.first?.network_secret?.nilIfEmpty == nil)
}

@MainActor
@Test func runSelectedConfigUsesKeychainNetworkSecret() async throws {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "run-secret"])
    let config = NetworkConfig(instance_id: "run-id", network_name: "office", network_secret: nil)
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()

    #expect(client.runConfigs.first?.network_secret == "run-secret")
    #expect(secrets.readPurposes == [.run])
    #expect(secrets.savePurposes.isEmpty)
}

@MainActor
@Test func runSelectedConfigPersistsEnteredSecretForTheNextLaunch() async {
    let firstClient = RecordingToggleClient()
    let secondClient = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore()
    let config = NetworkConfig(instance_id: "entered-secret-run-id", network_name: "office", network_secret: nil)
    let firstStore = EasyTierAppStore(client: firstClient, networkSecretStore: secrets)

    firstStore.configs = [config]
    firstStore.selectedConfigID = config.instance_id

    let outcome = await firstStore.runSelectedConfig(
        networkSecretInput: .edited("typed-secret")
    )

    #expect(firstClient.runConfigs.first?.network_secret == "typed-secret")
    #expect(secrets.secrets["office"] == "typed-secret")
    #expect(outcome.didPersistEditedSecret)
    #expect(secrets.savePurposes == [.update])
    #expect(secrets.readPurposes.isEmpty)

    let relaunchedStore = EasyTierAppStore(client: secondClient, networkSecretStore: secrets)
    relaunchedStore.configs = [config]
    relaunchedStore.selectedConfigID = config.instance_id

    await relaunchedStore.runSelectedConfig()

    #expect(secondClient.runConfigs.first?.network_secret == "typed-secret")
}

@MainActor
@Test func explicitKeychainSaveAndRemoveWorkWithoutRunningTheNetwork() async throws {
    let secrets = MemoryNetworkSecretStore()
    let config = NetworkConfig(instance_id: "explicit-save-id", network_name: "office")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    #expect(!(try await store.hasSavedNetworkSecret(for: config)))
    try await store.saveNetworkSecretToKeychain("saved-secret", for: config)
    #expect(try await store.hasSavedNetworkSecret(for: config))
    #expect(secrets.secrets["office"] == "saved-secret")

    try await store.removeNetworkSecretFromKeychain(for: config)
    #expect(!(try await store.hasSavedNetworkSecret(for: config)))
}

@MainActor
@Test func runSelectedConfigUsesAnAlreadyLoadedSecretWithoutKeychainAccess() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "keychain-secret"])
    let config = NetworkConfig(instance_id: "loaded-secret-run-id", network_name: "office")
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [config]
    store.selectedConfigID = config.id

    let outcome = await store.runSelectedConfig(
        networkSecretInput: .saved("loaded-secret")
    )

    #expect(client.runConfigs.first?.network_secret == "loaded-secret")
    #expect(!outcome.didPersistEditedSecret)
    #expect(secrets.savePurposes.isEmpty)
    #expect(secrets.readPurposes.isEmpty)
}

@MainActor
@Test func foregroundRestartReusesTheRuntimeSecretSessionCache() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "saved-secret"])
    let config = NetworkConfig(instance_id: "cached-restart-id", network_name: "office")
    let running = NetworkInstance(
        instance_id: config.id,
        name: config.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [config]
    store.selectedConfigID = config.id

    await store.runSelectedConfig()
    store.instances = [running]
    await store.stopSelectedConfig()
    store.instances = []
    await store.runSelectedConfig()
    store.instances = [running]
    await store.restartSelectedConfig(replacing: running, configID: config.id)

    #expect(secrets.readPurposes == [.run])
    #expect(secrets.savePurposes.isEmpty)
    #expect(client.runConfigs.map(\.network_secret) == [
        "saved-secret",
        "saved-secret",
        "saved-secret",
    ])
}

@MainActor
@Test func applicationFocusLossKeepsTheRuntimeSecretSessionCache() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "saved-secret"])
    let config = NetworkConfig(instance_id: "inactive-cache-id", network_name: "office")
    let running = NetworkInstance(
        instance_id: config.id,
        name: config.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [config]
    store.selectedConfigID = config.id

    await store.runSelectedConfig()
    store.instances = [running]
    await store.stopSelectedConfig()
    store.instances = []
    store.handleApplicationDidResignActive()
    await store.runSelectedConfig()

    #expect(secrets.readPurposes == [.run])
    #expect(secrets.savePurposes.isEmpty)
    #expect(secrets.authenticationInvalidationCount == 0)
}

@MainActor
@Test func applicationHideClearsTheRuntimeSecretSessionCache() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "saved-secret"])
    let config = NetworkConfig(instance_id: "hidden-cache-id", network_name: "office")
    let running = NetworkInstance(
        instance_id: config.id,
        name: config.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [config]
    store.selectedConfigID = config.id

    await store.runSelectedConfig()
    store.instances = [running]
    await store.stopSelectedConfig()
    store.instances = []
    store.handleApplicationDidHide()
    await store.runSelectedConfig()

    #expect(secrets.readPurposes == [.run, .run])
    #expect(secrets.authenticationInvalidationCount == 1)
}

@MainActor
@Test func applicationFocusLossDoesNotCancelAnInFlightNetworkStartSecretRead() async {
    let client = RecordingToggleClient()
    let secrets = BlockingNetworkSecretStore(secret: "saved-secret")
    let config = NetworkConfig(instance_id: "focus-loss-start-id", network_name: "office")
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [config]
    store.selectedConfigID = config.id

    let runTask = Task { await store.runSelectedConfig() }
    defer { secrets.releaseReads() }

    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while secrets.readCount == 0, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(secrets.readCount == 1)

    store.handleApplicationDidResignActive()
    #expect(secrets.authenticationInvalidationCount == 0)
    secrets.releaseReads()
    _ = await runTask.value

    #expect(client.runConfigs.first?.network_secret == "saved-secret")
}

@MainActor
@Test func manualRestartPersistsAnEditedSecretExactlyOnce() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "old-secret"])
    let config = NetworkConfig(instance_id: "edited-restart-id", network_name: "office")
    let running = NetworkInstance(
        instance_id: config.id,
        name: config.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [config]
    store.selectedConfigID = config.id
    store.instances = [running]

    let outcome = await store.restartSelectedConfig(
        replacing: running,
        configID: config.id,
        networkSecretInput: .edited("new-secret")
    )

    #expect(outcome.didPersistEditedSecret)
    #expect(secrets.savePurposes == [.update])
    #expect(secrets.readPurposes.isEmpty)
    #expect(secrets.secrets["office"] == "new-secret")
    #expect(client.runConfigs.first?.network_secret == "new-secret")
}

@MainActor
@Test func deletingASecretClearsTheRuntimeSecretSessionCache() async throws {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "first-secret"])
    let config = NetworkConfig(instance_id: "delete-cache-id", network_name: "office")
    let running = NetworkInstance(
        instance_id: config.id,
        name: config.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [config]
    store.selectedConfigID = config.id

    await store.runSelectedConfig()
    store.instances = [running]
    await store.stopSelectedConfig()
    store.instances = []
    try await store.removeNetworkSecretFromKeychain(for: config)
    secrets.secrets["office"] = "replacement-secret"
    await store.runSelectedConfig()

    #expect(secrets.readPurposes == [.run, .run])
    #expect(secrets.deletePurposes == [.delete])
    #expect(client.runConfigs.last?.network_secret == "replacement-secret")
}

@MainActor
@Test func applicationFocusLossDoesNotCancelAnInFlightNetworkDeletion() async {
    let secrets = BlockingNetworkSecretStore(secret: "saved-secret")
    let config = NetworkConfig(instance_id: "focus-loss-delete-id", network_name: "office")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [config]
    store.selectedConfigID = config.id

    let deleteTask = Task { await store.deleteSelectedConfig() }
    defer { secrets.releaseDeletes() }

    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while secrets.deleteCount == 0, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(secrets.deleteCount == 1)

    store.handleApplicationDidResignActive()
    #expect(secrets.authenticationInvalidationCount == 0)
    secrets.releaseDeletes()
    await deleteTask.value

    #expect(store.configs.isEmpty)
    #expect(store.lastError == nil)
    #expect(secrets.authenticationInvalidationCount == 1)
}

@MainActor
@Test func runSelectedConfigDoesNotStartWhenEnteredSecretCannotBeSaved() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore()
    secrets.saveError = EasyTierCoreError.operationFailed("keychain write failed")
    let config = NetworkConfig(instance_id: "failed-secret-save-id", network_name: "office")
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let outcome = await store.runSelectedConfig(
        networkSecretInput: .edited("typed-secret")
    )

    #expect(client.runConfigs.isEmpty)
    #expect(store.lastError?.contains("keychain write failed") == true)
    #expect(!outcome.didPersistEditedSecret)
    #expect(secrets.savePurposes == [.update])
    #expect(secrets.readPurposes.isEmpty)

    secrets.saveError = nil
    secrets.secrets["office"] = "saved-secret"
    await store.runSelectedConfig()

    #expect(secrets.readPurposes == [.run])
    #expect(client.runConfigs.first?.network_secret == "saved-secret")
}

@MainActor
@Test func canceledEditedSecretSavePreservesTheDraftAndDoesNotSurfaceAGlobalError() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore()
    secrets.saveError = NetworkSecretStoreError.keychain(errSecUserCanceled)
    let config = NetworkConfig(instance_id: "canceled-edited-secret-id", network_name: "office")
    let input = NetworkSecretInput.edited("typed-secret")
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [config]
    store.selectedConfigID = config.id

    let outcome = await store.runSelectedConfig(networkSecretInput: input)

    #expect(!outcome.didPersistEditedSecret)
    #expect(input.applying(outcome) == input)
    #expect(store.lastError == nil)
    #expect(client.runConfigs.isEmpty)
    #expect(secrets.savePurposes == [.update])
}

@MainActor
@Test func runSelectedConfigDoesNotStartAfterQuitBegins() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "quit-guard-id", network_name: "quit-guard-network")
    let store = EasyTierAppStore(client: client)
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.isQuitting = true

    await store.runSelectedConfig()

    #expect(client.runConfigs.isEmpty)
}

@MainActor
@Test func restartTargetsConfigMatchingOriginalInstanceAfterSelectionChanges() async {
    let client = RecordingToggleClient()
    let originalConfig = NetworkConfig(instance_id: "restart-original-id", network_name: "restart-original")
    let newlySelectedConfig = NetworkConfig(instance_id: "restart-selected-id", network_name: "restart-selected")
    let originalInstance = NetworkInstance(
        instance_id: originalConfig.instance_id,
        name: originalConfig.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client)
    store.configs = [originalConfig, newlySelectedConfig]
    store.selectedConfigID = newlySelectedConfig.instance_id
    store.instances = [originalInstance]

    await store.restartSelectedConfig(
        replacing: originalInstance,
        configID: originalConfig.instance_id
    )

    #expect(client.stoppedInstanceNames == [[originalConfig.network_name]])
    #expect(client.runConfigs.map(\.instance_id) == [originalConfig.instance_id])
}

@MainActor
@Test func applyConfigDraftSavesStoppedNetworkWithoutStartingIt() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["before": "saved-secret"])
    let original = NetworkConfig(instance_id: "auto-save-id", network_name: "before")
    var updated = original
    updated.network_name = "after"
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [original]

    let result = await store.applyConfigDraft(
        configID: original.instance_id,
        draft: updated,
        replacing: nil
    )

    #expect(result == .saved)
    #expect(store.configs.first?.network_name == "after")
    #expect(client.stoppedInstanceNames.isEmpty)
    #expect(client.runConfigs.isEmpty)
    #expect(secrets.savePurposes.isEmpty)
}

@MainActor
@Test func applyConfigDraftNeverPersistsASecretEmbeddedInTheConfiguration() async {
    let secrets = MemoryNetworkSecretStore()
    let original = NetworkConfig(instance_id: "transient-save-id", network_name: "office")
    var updated = original
    updated.network_secret = "typed-secret"
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [original]

    let result = await store.applyConfigDraft(
        configID: original.instance_id,
        draft: updated,
        replacing: nil
    )

    #expect(result == .saved)
    #expect(store.configs.first?.network_secret?.nilIfEmpty == nil)
    #expect(secrets.savePurposes.isEmpty)
    #expect(secrets.secrets.isEmpty)
}

@MainActor
@Test func unrelatedConfigurationEditDoesNotWriteTheNetworkSecret() async {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "saved-secret"])
    let original = NetworkConfig(instance_id: "unrelated-edit-id", network_name: "office")
    var updated = original
    updated.hostname = "updated-host"
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [original]

    let result = await store.applyConfigDraft(
        configID: original.id,
        draft: updated,
        replacing: nil
    )

    #expect(result == .saved)
    #expect(store.configs.first?.hostname == "updated-host")
    #expect(secrets.savePurposes.isEmpty)
    #expect(secrets.readPurposes.isEmpty)
}

@MainActor
@Test func applyConfigDraftRestartUsesTheSavedSecretWithoutPersistingAnEmbeddedDraft() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "saved-secret"])
    let original = NetworkConfig(instance_id: "transient-restart-id", network_name: "office")
    var updated = original
    updated.hostname = "updated-host"
    updated.network_secret = "typed-secret"
    let running = NetworkInstance(
        instance_id: original.instance_id,
        name: original.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [original]
    store.instances = [running]

    let result = await store.applyConfigDraft(
        configID: original.instance_id,
        draft: updated,
        replacing: running
    )

    #expect(result == .restarted)
    #expect(client.runConfigs.first?.network_secret == "saved-secret")
    #expect(secrets.savePurposes.isEmpty)
    #expect(secrets.readPurposes == [.restart])
    #expect(secrets.secrets["office"] == "saved-secret")
}

@MainActor
@Test func stopWithAnEditedSecretDraftDoesNotAccessKeychain() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "saved-secret"])
    let original = NetworkConfig(instance_id: "stop-secret-draft-id", network_name: "office")
    var updated = original
    updated.hostname = "updated-host"
    updated.network_secret = "typed-secret"
    let running = NetworkInstance(
        instance_id: original.instance_id,
        name: original.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [original]
    store.selectedConfigID = original.id
    store.instances = [running]

    await store.stopSelectedConfig()
    let result = await store.applyConfigDraft(
        configID: original.id,
        draft: updated,
        replacing: nil
    )

    #expect(result == .saved)
    #expect(client.stoppedInstanceNames == [[original.network_name]])
    #expect(store.configs.first?.hostname == "updated-host")
    #expect(secrets.savePurposes.isEmpty)
    #expect(secrets.readPurposes.isEmpty)
    #expect(secrets.deletedIDs.isEmpty)
    #expect(secrets.deletePurposes.isEmpty)
    #expect(secrets.authenticationPurposes.isEmpty)
    #expect(secrets.presenceCallCount == 0)
}

@MainActor
@Test func applyConfigDraftRestartsCapturedRunningInstance() async {
    let client = RecordingToggleClient()
    let original = NetworkConfig(instance_id: "auto-restart-id", network_name: "before")
    var updated = original
    updated.hostname = "after-host"
    let running = NetworkInstance(
        instance_id: original.instance_id,
        name: original.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client)
    store.configs = [original]
    store.instances = [running]

    let result = await store.applyConfigDraft(
        configID: original.instance_id,
        draft: updated,
        replacing: running
    )

    #expect(result == .restarted)
    #expect(client.stoppedInstanceNames == [[original.network_name]])
    #expect(client.runConfigs.first?.hostname == "after-host")
}

@MainActor
@Test func applyConfigDraftReturnsInlineFailureWithoutPresentingAGlobalError() async {
    let client = RecordingToggleClient()
    client.runError = EasyTierCoreError.operationFailed("automatic restart failed")
    let config = NetworkConfig(instance_id: "auto-failure-id", network_name: "auto-failure")
    let running = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client)
    store.configs = [config]
    store.instances = [running]

    let result = await store.applyConfigDraft(
        configID: config.instance_id,
        draft: config,
        replacing: running
    )

    #expect(result == .failed("automatic restart failed"))
    #expect(store.lastError == nil)
}
