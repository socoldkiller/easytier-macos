import Foundation
import Testing
@testable import EasyTierShared

@MainActor
@Test func applyRemoteConfigChangesValidatesRestartsAndConfirmsTheRemoteConfig() async throws {
    let client = RecordingToggleClient()
    let instanceID = "11111111-2222-3333-4444-555555555555"
    let original = NetworkConfig(instance_id: instanceID, hostname: "before-host")
    var updated = original
    updated.hostname = "after-host"

    let configObject = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(updated)) as? [String: Any]
    )
    let responseData = try JSONSerialization.data(withJSONObject: ["config": configObject])
    client.jsonRPCResponsesByMethod["get_config"] = String(decoding: responseData, as: UTF8.self)

    let member = NetworkMemberStatus(
        id: "remote-peer",
        isLocal: false,
        peerID: "42",
        instanceID: instanceID,
        virtualIPv4: "10.126.126.9/24",
        hostname: "remote-mac",
        version: "2.6.4",
        routeCost: "P2P",
        tunnelProto: "tcp",
        latency: "12 ms",
        uploadTotal: "1 KiB",
        downloadTotal: "2 KiB",
        lossRate: "0%",
        natType: "Open Internet",
        isPublicServer: false,
        txBytes: 1_024,
        rxBytes: 2_048
    )
    let store = EasyTierAppStore(client: client)
    store.remoteConfigSession = RemoteConfigSession(
        rpcURL: try #require(URL(string: "tcp://10.126.126.9:15888")),
        instanceID: instanceID,
        member: member,
        config: updated,
        originalConfig: original,
        isLoading: false,
        loadError: nil
    )

    let success = await store.applyRemoteConfigChanges()

    #expect(success)
    #expect(store.remoteConfigSession?.originalConfig == updated)
    #expect(store.remoteConfigSession?.originalConfigPayload != nil)
    #expect(store.remoteConfigSession?.applyState == .applied)
    #expect(client.jsonRPCCalls.map(\.method) == ["validate_config", "run_network_instance", "get_config"])
}

@MainActor
@Test func longSystemSleepRestartsPreviouslyRunningConfig() async throws {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "wake-secret"])
    let config = NetworkConfig(instance_id: "wake-id", network_name: "office", network_secret: nil)
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    store.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: readyDetail
        ),
    ]
    store.runtimeDetails = [config.network_name: readyDetail]
    client.networkInfos = [
        config.network_name: readyDetail,
    ]

    store.handleSystemWillSleep(now: Date(timeIntervalSince1970: 100))
    await store.handleSystemDidWake(now: Date(timeIntervalSince1970: 160))

    #expect(client.stoppedInstanceNames == [[config.network_name]])
    #expect(client.runConfigs.map(\.instance_id) == [config.instance_id])
    #expect(client.runConfigs.first?.network_secret == "wake-secret")
}

@MainActor
@Test func longSystemSleepDoesNotRestartStartingConfig() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "starting-wake-id", network_name: "starting-office")
    let store = EasyTierAppStore(client: client)

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: NetworkInstanceRunningInfo(running: true, instance_id: config.instance_id)
        ),
    ]

    store.handleSystemWillSleep(now: Date(timeIntervalSince1970: 100))
    await store.handleSystemDidWake(now: Date(timeIntervalSince1970: 160))

    #expect(client.stoppedInstanceNames.isEmpty)
    #expect(client.runConfigs.isEmpty)
}

@MainActor
@Test func shortSystemSleepOnlyRefreshesRuntime() async throws {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "short-wake-id", network_name: "office")
    let store = EasyTierAppStore(client: client)

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)]
    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(running: true, instance_id: config.instance_id),
    ]

    store.handleSystemWillSleep(now: Date(timeIntervalSince1970: 100))
    await store.handleSystemDidWake(now: Date(timeIntervalSince1970: 110))

    #expect(client.stoppedInstanceNames.isEmpty)
    #expect(client.runConfigs.isEmpty)
    #expect(store.instances.first?.instance_id == config.instance_id)
}

@MainActor
@Test func runningRuntimePreventsIdleSystemSleep() async {
    let client = RecordingToggleClient()
    let sleepPreventer = RecordingSystemSleepPreventer()
    let config = NetworkConfig(instance_id: "awake-id", network_name: "office")
    let store = EasyTierAppStore(client: client, systemSleepPreventer: sleepPreventer)
    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(running: true, instance_id: config.instance_id),
    ]

    await store.refreshRuntime()

    #expect(sleepPreventer.isPreventingSystemSleep)
    #expect(sleepPreventer.calls.last?.prevented == true)
}

@MainActor
@Test func idleSystemSleepAssertionIsReleasedWhenRuntimeStops() async {
    let client = RecordingToggleClient()
    let sleepPreventer = RecordingSystemSleepPreventer()
    let config = NetworkConfig(instance_id: "awake-release-id", network_name: "office")
    let store = EasyTierAppStore(client: client, systemSleepPreventer: sleepPreventer)
    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(running: true, instance_id: config.instance_id),
    ]
    await store.refreshRuntime()

    client.networkInfos = [:]
    await store.refreshRuntime()

    #expect(!sleepPreventer.isPreventingSystemSleep)
    #expect(sleepPreventer.calls.map(\.prevented) == [true, false])
}

@MainActor
@Test func exportSelectedTOMLIsRedactedByDefaultWithoutReadingKeychain() async throws {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "export-secret"])
    let config = NetworkConfig(instance_id: "redacted-export-id", network_name: "office")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let toml = try await store.exportSelectedTOML()

    #expect(!toml.contains("network_secret"))
    #expect(!toml.contains("export-secret"))
    #expect(secrets.readReasons.isEmpty)
}

@MainActor
@Test func exportSelectedTOMLUsesKeychainNetworkSecret() async throws {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "export-secret"])
    let config = NetworkConfig(instance_id: "export-id", network_name: "office", network_secret: nil)
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let toml = try await store.exportSelectedTOML(
        options: TOMLExportOptions(includeNetworkSecret: true)
    )

    #expect(toml.contains("export-secret"))
}

@MainActor
@Test func applicationFocusLossDoesNotStripAnInFlightPlaintextExport() async throws {
    let secrets = BlockingNetworkSecretStore(secret: "export-secret")
    let config = NetworkConfig(instance_id: "focus-loss-export-id", network_name: "office")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [config]
    store.selectedConfigID = config.id

    let exportTask = Task {
        try await store.exportSelectedTOML(
            options: TOMLExportOptions(includeNetworkSecret: true)
        )
    }
    defer { secrets.releaseReads() }

    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while secrets.readCount == 0, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(secrets.readCount == 1)

    store.handleApplicationDidResignActive()
    #expect(secrets.authenticationInvalidationCount == 0)
    secrets.releaseReads()

    let toml = try await exportTask.value
    #expect(toml.contains("network_secret = \"export-secret\""))
}

@MainActor
@Test func runtimeCacheNeverBypassesFreshRevealOrPlaintextExport() async throws {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "saved-secret"])
    let config = NetworkConfig(instance_id: "fresh-secret-action-id", network_name: "office")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [config]
    store.selectedConfigID = config.id

    await store.runSelectedConfig()
    _ = try await store.revealNetworkSecret(for: config)
    _ = try await store.exportSelectedTOML(
        options: TOMLExportOptions(includeNetworkSecret: true)
    )

    #expect(secrets.readPurposes == [.run, .reveal, .export])
}

@MainActor
@Test func exportSelectedTOMLPrefersTransientSecretWithoutReadingKeychain() async throws {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "saved-secret"])
    let config = NetworkConfig(instance_id: "transient-export-id", network_name: "office")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let toml = try await store.exportSelectedTOML(
        options: TOMLExportOptions(includeNetworkSecret: true),
        networkSecretInput: .edited("typed-secret")
    )

    #expect(toml.contains("network_secret = \"typed-secret\""))
    #expect(!toml.contains("saved-secret"))
    #expect(secrets.readReasons.isEmpty)
    #expect(secrets.authenticationPurposes == [.export])
}

@MainActor
@Test func exportSelectedTOMLAppliesMagicDNSSettingsOverlay() async throws {
    var config = NetworkConfig(instance_id: "dns-export-id", network_name: "office")
    config.enable_magic_dns = true
    let store = EasyTierAppStore(client: RecordingToggleClient())
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.magicDNSSettings = try MagicDNSSettings(dnsSuffix: "lab.internal")

    let toml = try await store.exportSelectedTOML()

    #expect(toml.contains("accept_dns = true"))
    #expect(toml.contains("tld_dns_zone = \"lab.internal.\""))
}

@MainActor
@Test func runSelectedConfigAppliesMagicDNSSettingsOverlay() async throws {
    let client = RecordingToggleClient()
    var config = NetworkConfig(instance_id: "dns-run-id", network_name: "office")
    config.enable_magic_dns = true
    config.no_tun = true
    let store = EasyTierAppStore(client: client)
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.magicDNSSettings = try MagicDNSSettings(dnsSuffix: "lab.internal")

    await store.runSelectedConfig()

    #expect(client.runTOMLs.first?.contains("tld_dns_zone = \"lab.internal.\"") == true)
}

@MainActor
@Test func importTOMLPromotesMagicDNSSuffixToAppSettings() async throws {
    var config = NetworkConfig(instance_id: "dns-import-id", network_name: "office")
    config.enable_magic_dns = true
    let toml = try NetworkConfigTOMLCodec.encode(
        config,
        magicDNSSettings: try MagicDNSSettings(dnsSuffix: "imported.internal")
    )
    let store = EasyTierAppStore()

    await store.importTOML(toml)

    #expect(store.magicDNSSettings.dnsSuffix == "imported.internal.")
    #expect(store.configs.first?.enable_magic_dns == true)
    #expect(store.configs.count == 1)
}

@MainActor
@Test func changingMagicDNSSuffixRecordsRestartNoticeForRunningMagicDNSNetwork() async throws {
    let client = RecordingToggleClient()
    var config = NetworkConfig(instance_id: "dns-notice-id", network_name: "office")
    config.enable_magic_dns = true
    let store = EasyTierAppStore(client: client)
    store.configs = [config]
    store.instances = [NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)]

    await store.applyMode(.default, magicDNSSettings: try MagicDNSSettings(dnsSuffix: "lab.internal"))

    #expect(store.logLines.contains { $0.text.contains("Magic DNS suffix changed") && $0.text.contains("Restart office") })
}

@MainActor
@Test func changingOnlyMagicDNSSuffixDoesNotReconfigureRPCPortal() async throws {
    let client = RecordingToggleClient()
    let backend = HelperRegistrationBackendSpy(status: .enabled)
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)
    let store = EasyTierAppStore(
        runtimeClient: client,
        helperRegistration: registration,
        storage: .isolatedForTesting()
    )

    #expect(await store.prepareRuntimeServiceAfterLaunch())

    await store.applyMode(
        store.mode,
        magicDNSSettings: try MagicDNSSettings(dnsSuffix: "lab.internal")
    )

    #expect(client.configuredRPCPortals == [AppMode.default.rpcPortal])
}

@MainActor
@Test func magicDNSResolverIsActiveOnlyForRunningEnabledNetworks() {
    var magicDNSConfig = NetworkConfig(instance_id: "magic-dns", network_name: "magic")
    magicDNSConfig.enable_magic_dns = true
    let plainConfig = NetworkConfig(instance_id: "plain", network_name: "plain")
    let store = EasyTierAppStore(client: RecordingToggleClient())
    store.configs = [magicDNSConfig, plainConfig]

    #expect(!store.isMagicDNSResolverActive)

    store.instances = [
        NetworkInstance(instance_id: plainConfig.instance_id, name: plainConfig.network_name, running: true),
    ]
    #expect(!store.isMagicDNSResolverActive)

    store.instances.append(
        NetworkInstance(instance_id: magicDNSConfig.instance_id, name: magicDNSConfig.network_name, running: true)
    )
    #expect(store.isMagicDNSResolverActive)

    store.instances.removeAll { $0.instance_id == magicDNSConfig.instance_id }
    #expect(!store.isMagicDNSResolverActive)
}

@Test func storagePersistsMagicDNSSettingsInSnapshotOnly() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    var config = NetworkConfig(instance_id: "dns-storage-id", network_name: "office")
    config.enable_magic_dns = true
    let snapshot = AppSnapshot(
        configIDs: [config.id],
        mode: .default,
        lastSelectedConfigID: config.instance_id,
        magicDNSSettings: try MagicDNSSettings(dnsSuffix: "stored.internal")
    )

    try storage.save(snapshot, configs: [config])

    let loaded = try storage.load()
    let tomlURL = directory.appendingPathComponent("configs/dns-storage-id.toml")
    let toml = try String(contentsOf: tomlURL, encoding: .utf8)

    #expect(loaded.snapshot.magicDNSSettings.dnsSuffix == "stored.internal.")
    #expect(!toml.contains("tld_dns_zone"))
}
