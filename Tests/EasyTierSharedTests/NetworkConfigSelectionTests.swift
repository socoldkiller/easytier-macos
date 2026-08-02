import Foundation
import Testing
@testable import EasyTierShared

@MainActor
@Test func preparingForRemoteAccountChangeClearsManagedSelectionAndCaches() {
    let store = EasyTierAppStore(client: RecordingToggleClient())
    let managed = NetworkInstance(instance_id: "managed-id", name: "managed-network", running: true)
    store.instances = [managed]
    store.setConfigurationAuthority(.configServer)
    store.runtimeManagedConfigDetails[managed.instance_id] = NetworkConfig(
        instance_id: managed.instance_id,
        network_name: managed.name
    )
    store.runtimeManagedConfigLoadErrors[managed.instance_id] = "stale"

    store.prepareForRemoteAccountChange()

    #expect(store.configurationAuthority == .configServer)
    #expect(store.selectedConfigID == nil)
    #expect(store.runtimeManagedConfigDetails.isEmpty)
    #expect(store.runtimeManagedConfigLoadErrors.isEmpty)
    #expect(store.remoteConfigSession == nil)
}

@MainActor
@Test func selectNextConfigCyclesThroughConfigsAndPersistsSelection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    let store = EasyTierAppStore(client: RecordingToggleClient(), storage: storage)

    store.configs = [first, second]
    store.selectedConfigID = first.instance_id

    await store.selectNextConfig()

    #expect(store.selectedConfigID == second.instance_id)
    let persisted = try await ApplicationDatabase(
        baseDirectory: directory,
        gatewayFileURL: directory.appending(path: "gateway/config.json"),
        networkSecretStore: MemoryNetworkSecretStore()
    ).loadWorkspace()
    #expect(persisted.selectedConfigID == second.instance_id)

    await store.selectNextConfig()

    #expect(store.selectedConfigID == first.instance_id)
}

@MainActor
@Test func selectPreviousConfigWrapsToLastConfig() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    let store = EasyTierAppStore(client: RecordingToggleClient(), storage: storage)

    store.configs = [first, second]
    store.selectedConfigID = first.instance_id

    await store.selectPreviousConfig()

    #expect(store.selectedConfigID == second.instance_id)
}

@MainActor
@Test func adjacentConfigSelectionStartsAtDirectionalEdgeWhenSelectionIsMissing() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    let store = EasyTierAppStore(client: RecordingToggleClient(), storage: storage)

    store.configs = [first, second]
    store.selectedConfigID = nil

    await store.selectNextConfig()

    #expect(store.selectedConfigID == first.instance_id)

    store.selectedConfigID = nil
    await store.selectPreviousConfig()

    #expect(store.selectedConfigID == second.instance_id)
}

@MainActor
@Test func invalidLegacySelectionEntersRestrictedRecoveryMode() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let config = NetworkConfig(instance_id: "current-id", network_name: "current-network")
    let snapshot = AppSnapshot(configIDs: [config.id], mode: .default, lastSelectedConfigID: "missing-id")
    try storage.save(snapshot, configs: [config])

    let store = EasyTierAppStore(client: RecordingToggleClient(), storage: storage)

    await store.load()
    store.stopPolling()

    #expect(!store.persistenceIsReady)
    #expect(FileManager.default.fileExists(atPath: storage.configURL(forID: config.id).path))
    #expect(FileManager.default.fileExists(atPath: directory.appending(path: "state.json").path))
}

@MainActor
@Test func loadKeepsSavedEmptyConfigList() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    try storage.save(AppSnapshot(configIDs: [], mode: .default, lastSelectedConfigID: nil), configs: [])

    let store = EasyTierAppStore(client: RecordingToggleClient(), storage: storage)

    await store.load()
    store.stopPolling()

    #expect(store.configs.isEmpty)
    #expect(store.selectedConfigID == nil)
}

@MainActor
@Test func runtimePollingContinuesWhileAViewIsScrolling() async {
    let client = BlockingRuntimeMutationClient()
    let store = EasyTierAppStore(client: client)
    store.isAnyViewScrolling = true

    store.startPolling()
    defer { store.stopPolling() }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    var counts = await client.counts()
    while counts.collects == 0, clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
        counts = await client.counts()
    }
    #expect(counts.collects >= 1)
}

@MainActor
@Test func applyModeConfiguresRPCPortal() async throws {
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)

    await store.applyMode(AppMode(
        rpcListenEnabled: true,
        rpcListenPort: 15_998,
        rpcPortalWhitelist: ["127.0.0.0/8", "10.126.126.0/24"]
    ))
    await store.applyMode(AppMode(
        rpcListenEnabled: false,
        rpcListenPort: 15_998,
        rpcPortalWhitelist: ["127.0.0.0/8"]
    ))

    #expect(client.configuredRPCPortals == ["tcp://0.0.0.0:15998", nil])
    #expect(client.configuredRPCPortalWhitelists == [["127.0.0.0/8", "10.126.126.0/24"], ["127.0.0.0/8"]])
}

@MainActor
@Test func selectedRunningInstanceDoesNotFallBackToFirstInstance() {
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    let store = EasyTierAppStore(client: RecordingToggleClient())

    store.configs = [first, second]
    store.selectedConfigID = second.instance_id
    store.instances = [NetworkInstance(instance_id: first.instance_id, name: first.network_name, running: true)]

    #expect(store.selectedRunningInstance == nil)
    #expect(store.selectedMemberStatuses.isEmpty)
}

@MainActor
@Test func selectedRunningInstancePrefersInstanceIDWhenNamesMatch() throws {
    let first = NetworkConfig(instance_id: "first-id", network_name: "shared-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "shared-network")
    let store = EasyTierAppStore(client: RecordingToggleClient())

    store.configs = [first, second]
    store.selectedConfigID = second.instance_id
    store.instances = [
        NetworkInstance(instance_id: first.instance_id, name: first.network_name, running: true),
        NetworkInstance(instance_id: second.instance_id, name: second.network_name, running: true),
    ]

    let selected = try #require(store.selectedRunningInstance)
    #expect(selected.instance_id == second.instance_id)
}

@MainActor
@Test func selectedRunningInstanceUsesLegacyRuntimeNameWhenConfigNameIsUnique() throws {
    let config = NetworkConfig(instance_id: "config-id", network_name: "legacy-runtime-name")
    let store = EasyTierAppStore(client: RecordingToggleClient())

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(instance_id: config.network_name, name: config.network_name, running: true)]

    let selected = try #require(store.selectedRunningInstance)
    #expect(selected.instance_id == config.network_name)
}

@MainActor
@Test func restartSelectedConfigStopsOldRuntimeNameBeforeRunningUpdatedConfig() async throws {
    let original = NetworkConfig(instance_id: "config-id", network_name: "old-network")
    var updated = original
    updated.network_name = "new-network"
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)
    let runningInstance = NetworkInstance(instance_id: original.network_name, name: original.network_name, running: true)

    store.configs = [original]
    store.selectedConfigID = original.instance_id
    store.instances = [runningInstance]
    try await store.updateConfig(id: original.instance_id, with: updated)

    await store.restartSelectedConfig(replacing: runningInstance)

    #expect(client.stoppedInstanceNames == [[original.network_name]])
    #expect(client.runConfigs.map(\.network_name) == [updated.network_name])
}

@MainActor
@Test func selectedRunningInstanceDoesNotUseAmbiguousNameFallback() {
    let first = NetworkConfig(instance_id: "first-id", network_name: "shared-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "shared-network")
    let store = EasyTierAppStore(client: RecordingToggleClient())

    store.configs = [first, second]
    store.selectedConfigID = second.instance_id
    store.instances = [NetworkInstance(instance_id: "shared-network", name: "shared-network", running: true)]

    #expect(store.selectedRunningInstance == nil)
    #expect(!store.selectedConfigIsRunning)
}

@MainActor
@Test func toggleSelectedConfigConnectionRunsSelectedStoppedNetwork() async {
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    var second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    second.listener_urls = ["tcp://0.0.0.0:12010", "udp://0.0.0.0:12010", "wg://0.0.0.0:12011"]
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)

    store.configs = [first, second]
    store.selectedConfigID = second.instance_id
    store.instances = [NetworkInstance(instance_id: first.instance_id, name: first.network_name, running: true)]

    await store.toggleSelectedConfigConnection()

    #expect(client.runConfigs.map(\.instance_id) == [second.instance_id])
    #expect(client.stoppedInstanceNames.isEmpty)
    #expect(client.retainedInstanceNames.isEmpty)
}

@MainActor
@Test func toggleSelectedConfigConnectionStopsOnlySelectedRunningNetwork() async {
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)

    store.configs = [first, second]
    store.selectedConfigID = second.instance_id
    store.instances = [
        NetworkInstance(instance_id: first.instance_id, name: first.network_name, running: true),
        NetworkInstance(instance_id: second.instance_id, name: second.network_name, running: true),
    ]

    await store.toggleSelectedConfigConnection()

    #expect(client.stoppedInstanceNames == [[second.network_name]])
    #expect(client.retainedInstanceNames.isEmpty)
    #expect(client.runConfigs.isEmpty)
}

@MainActor
@Test func toggleConfigConnectionTargetsRequestedNetworkWithoutChangingSelection() async {
    let first = NetworkConfig(instance_id: "first-explicit-id", network_name: "first-network")
    var second = NetworkConfig(instance_id: "second-explicit-id", network_name: "second-network")
    second.listener_urls = ["tcp://0.0.0.0:12020", "udp://0.0.0.0:12020", "wg://0.0.0.0:12021"]
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)

    store.configs = [first, second]
    store.selectedConfigID = first.id

    await store.toggleConfigConnection(id: second.id)

    #expect(store.selectedConfigID == first.id)
    #expect(client.runConfigs.map(\.instance_id) == [second.id])
}

@MainActor
@Test func toggleConfigConnectionStopsOnlyRequestedNetworkWithoutChangingSelection() async {
    let first = NetworkConfig(instance_id: "first-running-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-running-id", network_name: "second-network")
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)

    store.configs = [first, second]
    store.selectedConfigID = first.id
    store.instances = [
        NetworkInstance(instance_id: first.id, name: first.network_name, running: true),
        NetworkInstance(instance_id: second.id, name: second.network_name, running: true),
    ]

    await store.toggleConfigConnection(id: second.id)

    #expect(store.selectedConfigID == first.id)
    #expect(client.stoppedInstanceNames == [[second.network_name]])
    #expect(client.runConfigs.isEmpty)
}

@MainActor
@Test func toggleConfigConnectionIgnoresMissingAndManagedNetworks() async {
    let local = NetworkConfig(instance_id: "local-id", network_name: "local-network")
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)
    store.configs = [local]
    store.selectedConfigID = local.id

    await store.toggleConfigConnection(id: "missing-id")
    store.setConfigurationAuthority(.configServer)
    await store.toggleConfigConnection(id: local.id)

    #expect(client.runConfigs.isEmpty)
    #expect(client.stoppedInstanceNames.isEmpty)
}

@MainActor
@Test func stopSelectedConfigPersistsRuntimeHostnameBeforeStopping() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    var config = NetworkConfig(instance_id: "device-id", hostname: "old-host", network_name: "office")
    config.listener_urls = ["tcp://0.0.0.0:13010", "udp://0.0.0.0:13010", "wg://0.0.0.0:13011"]
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client, storage: storage)

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: NetworkInstanceRunningInfo(my_node_info: NodeInfo(hostname: "new-host"))
    )]

    await store.stopSelectedConfig()

    #expect(store.configs.first?.hostname == "new-host")
    let persisted = try await ApplicationDatabase(
        baseDirectory: directory,
        gatewayFileURL: directory.appending(path: "gateway/config.json"),
        networkSecretStore: MemoryNetworkSecretStore()
    ).loadWorkspace()
    #expect(persisted.configs.first?.hostname == "new-host")
    #expect(client.stoppedInstanceNames == [[config.network_name]])
}

@MainActor
@Test func runtimeIntentReplaysHostnameWhenRuntimeReturnedToBase() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    let config = NetworkConfig(instance_id: "11111111-1111-1111-1111-111111111111", network_name: "office")
    store.configs = [config]
    store.runtimeIntents = [hostnameIntent(
        instanceID: config.instance_id,
        networkName: config.network_name,
        base: "base",
        desired: "desired"
    )]
    client.networkInfos = [
        config.instance_id: NetworkInstanceRunningInfo(my_node_info: NodeInfo(hostname: "base")),
    ]

    await store.refreshRuntime()

    #expect(client.jsonRPCCalls.map(\.method) == ["patch_config"])
    #expect(client.runConfigs.isEmpty)
    #expect(client.stoppedInstanceNames.isEmpty)
    let object = try networkConfigRPCRequestPayloadObject(client.jsonRPCCalls[0].payload)
    let patch = object["patch"] as? [String: Any]
    #expect(patch?["hostname"] as? String == "desired")
    #expect(store.runtimeIntents.first?.status == .pending)
}

@MainActor
@Test func runtimeIntentDoesNotReplayWhenRuntimeAlreadyMatchesDesired() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    let config = NetworkConfig(instance_id: "11111111-1111-1111-1111-111111111111", network_name: "office")
    store.configs = [config]
    store.runtimeIntents = [hostnameIntent(
        instanceID: config.instance_id,
        networkName: config.network_name,
        base: "base",
        desired: "desired"
    )]
    client.networkInfos = [
        config.instance_id: NetworkInstanceRunningInfo(my_node_info: NodeInfo(hostname: "desired")),
    ]

    await store.refreshRuntime()

    #expect(client.jsonRPCCalls.isEmpty)
    #expect(store.runtimeIntents.first?.status == .applied)
}

@MainActor
@Test func runtimeIntentMarksConflictWhenRuntimeHasThirdPartyValue() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    let config = NetworkConfig(instance_id: "11111111-1111-1111-1111-111111111111", network_name: "office")
    store.configs = [config]
    store.runtimeIntents = [hostnameIntent(
        instanceID: config.instance_id,
        networkName: config.network_name,
        base: "base",
        desired: "desired"
    )]
    client.networkInfos = [
        config.instance_id: NetworkInstanceRunningInfo(my_node_info: NodeInfo(hostname: "someone-else")),
    ]

    await store.refreshRuntime()

    #expect(client.jsonRPCCalls.isEmpty)
    #expect(store.runtimeIntents.first?.status == .conflict)
}

@MainActor
@Test func localHostnameRuntimeIntentDoesNotRestartWhenRPCFails() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let client = RecordingToggleClient()
    client.jsonRPCError = EasyTierCoreError.operationFailed("rpc unavailable")
    let store = EasyTierAppStore(client: client, storage: storage)
    var config = NetworkConfig(instance_id: "11111111-1111-1111-1111-111111111111", hostname: "base", network_name: "office")
    config.listener_urls = ["tcp://0.0.0.0:11010", "udp://0.0.0.0:11010", "wg://0.0.0.0:11011"]
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    var updated = config
    updated.hostname = "desired"
    try await store.updateConfig(id: config.instance_id, with: updated, saveImmediately: true)
    let running = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: NetworkInstanceRunningInfo(my_node_info: NodeInfo(hostname: "base"))
    )
    store.instances = [running]

    await store.applyLocalHostnameRuntimeIntent(
        configID: config.instance_id,
        runningInstance: running,
        desiredHostname: "desired",
        baseHostname: "base"
    )

    #expect(client.runConfigs.isEmpty)
    #expect(client.stoppedInstanceNames.isEmpty)
    #expect(client.jsonRPCCalls.map(\.method) == ["patch_config"])
    #expect(store.runtimeIntents.first?.status == .unreachable)
    let persisted = try await ApplicationDatabase(
        baseDirectory: directory,
        gatewayFileURL: directory.appending(path: "gateway/config.json"),
        networkSecretStore: MemoryNetworkSecretStore()
    ).loadWorkspace()
    #expect(persisted.configs.first?.hostname == "desired")
}

@MainActor
@Test func runSelectedConfigReportsRunningPortConflictBeforeStarting() async {
    var running = NetworkConfig(instance_id: "running-id", network_name: "running")
    running.listener_urls = ["tcp://0.0.0.0:11010"]
    var selected = NetworkConfig(instance_id: "selected-id", network_name: "selected")
    selected.listener_urls = ["tcp://127.0.0.1:11010"]
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)

    store.configs = [running, selected]
    store.selectedConfigID = selected.instance_id
    store.instances = [NetworkInstance(instance_id: running.instance_id, name: running.network_name, running: true)]

    await store.runSelectedConfig()

    #expect(client.runConfigs.count == 1)
    #expect(store.lastError == nil)
}

@MainActor
@Test func deleteSelectedConfigKeepsConfigWhenRunningInstanceCannotStop() async {
    let config = NetworkConfig(instance_id: "running-id", network_name: "running-network")
    let client = RecordingToggleClient()
    client.stopError = EasyTierCoreError.operationFailed("stop failed")
    let store = EasyTierAppStore(client: client)

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)]

    await store.deleteSelectedConfig()

    #expect(store.configs.map(\.id) == [config.instance_id])
    #expect(store.selectedConfigID == config.instance_id)
    #expect(client.stoppedInstanceNames == [[config.network_name]])
    #expect(store.lastError?.contains("stop failed") == true)
}

@MainActor
@Test func deleteSelectedConfigStopsByPersistedNameWhenRuntimeSnapshotIsEmpty() async {
    let config = NetworkConfig(instance_id: "last-id", network_name: "last-network")
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.deleteSelectedConfig()

    #expect(client.stoppedInstanceNames == [[config.network_name]])
    #expect(store.configs.isEmpty)
    #expect(store.selectedConfigID == nil)
}

@Test func privilegedHelperUnavailableErrorIsActionable() {
    let message = PrivilegedHelperError.unavailable.localizedDescription
    #expect(message.contains("privileged helper"))
    #expect(message.contains("starting a network"))
}

@Test func privilegedHelperApprovalErrorAppliesToAllNetworkModes() {
    let message = PrivilegedHelperError.needsRegistration.localizedDescription
    #expect(message.contains("background permission"))
    #expect(message.contains("run network instances"))
    #expect(!message.contains("TUN"))
}

@Test func privilegedHelperErrorPayloadRoundTripsAndFeedsLocalizedDescription() throws {
    let payload = PrivilegedHelperErrorPayload(
        code: "runFailed",
        message: "TUN device creation failed.",
        recoverySuggestion: "Reinstall the privileged helper."
    )

    let decoded = try PrivilegedHelperErrorPayload.decode(from: payload.encodedString())
    let message = PrivilegedHelperError.helperReported(decoded).localizedDescription

    #expect(decoded == payload)
    #expect(message.contains("TUN device creation failed."))
    #expect(message.contains("Reinstall the privileged helper."))
}
