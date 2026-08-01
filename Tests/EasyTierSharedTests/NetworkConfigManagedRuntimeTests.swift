import Foundation
import Testing
@testable import EasyTierShared

@MainActor
@Test func appStoreSelectedRuntimeSnapshotsFollowSelectedConfig() throws {
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: RecordingToggleClient(), storage: EasyTierStorage(baseDirectory: directory))
    let firstSample = TrafficSample(timestamp: Date(timeIntervalSince1970: 1), txBytesPerSecond: 1, rxBytesPerSecond: 2)
    let secondSample = TrafficSample(timestamp: Date(timeIntervalSince1970: 2), txBytesPerSecond: 3, rxBytesPerSecond: 4)

    store.configs = [
        first,
        second,
    ]
    store.selectedConfigID = first.instance_id
    store.instances = [
        NetworkInstance(instance_id: first.instance_id, name: first.network_name, running: true),
        NetworkInstance(instance_id: second.instance_id, name: second.network_name, running: true),
    ]
    store.runtimeDetails = [
        first.network_name: NetworkInstanceRunningInfo(dev_name: "first-device", running: true, instance_id: first.instance_id),
        second.network_name: NetworkInstanceRunningInfo(dev_name: "second-device", running: true, instance_id: second.instance_id),
    ]
    store.trafficSamplesByInstance = [
        first.network_name: [firstSample],
        second.network_name: [secondSample],
    ]

    #expect(store.selectedStatusSnapshot.networkName == first.network_name)
    #expect(store.selectedStatusSnapshot.deviceName == "first-device")
    #expect(store.selectedTrafficSnapshot.samples.map(\.id) == [firstSample.id])

    store.selectedConfigID = second.instance_id

    #expect(store.selectedStatusSnapshot.networkName == second.network_name)
    #expect(store.selectedStatusSnapshot.deviceName == "second-device")
    #expect(store.selectedTrafficSnapshot.samples.map(\.id) == [secondSample.id])
}

@MainActor
@Test func appStoreProjectsConfigServerRuntimeIntoExistingStatusPresentation() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    store.setConfigurationAuthority(.configServer)
    client.networkInfos = [
        "managed-network": NetworkInstanceRunningInfo(
            dev_name: "utun-managed",
            my_node_info: NodeInfo(
                ipv4_addr: "10.0.64.1/24",
                hostname: "managed-mac",
                peer_id: 7
            ),
            running: true,
            instance_id: "managed-id"
        ),
    ]

    await store.refreshRuntime()

    #expect(store.configs.isEmpty)
    #expect(store.runtimeManagedConfigs.map(\.id) == ["managed-id"])
    #expect(store.presentedConfigs.map(\.network_name) == ["managed-network"])
    #expect(store.selectedConfigID == "managed-id")
    #expect(store.selectedConfigIsRuntimeManaged)
    #expect(store.selectedStatusSnapshot.hasRunningInstance)
    #expect(store.selectedStatusSnapshot.networkName == "managed-network")
    #expect(store.selectedStatusSnapshot.deviceName == "utun-managed")
}

@MainActor
@Test func configServerManagedWorkspaceRejectsAddingALocalNetwork() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let client = RecordingToggleClient()
    let secretStore = MemoryNetworkSecretStore()
    let database = ApplicationDatabase(
        baseDirectory: directory,
        gatewayFileURL: directory.appending(path: "gateway/config.json"),
        networkSecretStore: secretStore
    )
    try await database.saveWorkspace(WorkspacePersistenceState(configs: [], selectedConfigID: nil))
    let store = EasyTierAppStore(
        runtimeClient: client,
        storage: EasyTierStorage(baseDirectory: directory),
        database: database,
        networkSecretStore: secretStore
    )
    store.setConfigurationAuthority(.configServer)
    client.networkInfos = [
        "easytier": NetworkInstanceRunningInfo(
            running: true,
            instance_id: "managed-id"
        ),
    ]

    await store.refreshRuntime()
    #expect(store.selectedConfigID == "managed-id")

    await store.addConfig()

    #expect(store.configs.isEmpty)
    #expect(store.runtimeManagedConfigs.map(\.id) == ["managed-id"])
    #expect(store.selectedConfigID == "managed-id")
    let persisted = try await database.loadWorkspace()
    #expect(persisted.configs.isEmpty)
}

@MainActor
@Test func sameNamedLocalConfigDoesNotClaimAConfigServerInstance() {
    let local = NetworkConfig(instance_id: "local-id", network_name: "easytier")
    let managed = NetworkInstance(instance_id: "managed-id", name: "easytier", running: true)
    let store = EasyTierAppStore(client: RecordingToggleClient())
    store.configs = [local]
    store.instances = [managed]

    #expect(store.localConfig(matching: managed) == nil)
    #expect(store.runtimeManagedConfigs.map(\.id) == [managed.instance_id])
    #expect(store.runningInstance(matching: local) == nil)
}

@MainActor
@Test func configServerRuntimeLoadsItsConfigurationForReadOnlyPresentation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    store.setConfigurationAuthority(.configServer)
    let instanceID = "11111111-2222-3333-4444-555555555555"
    let remoteConfig = NetworkConfig(
        instance_id: instanceID,
        hostname: "managed-mac",
        network_name: "managed-network",
        network_secret: "not-for-presentation",
        peer_urls: ["tcp://peer.example.com:11010"],
        listener_urls: ["tcp://0.0.0.0:11010"],
        no_tun: true
    )
    let configObject = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(remoteConfig)) as? [String: Any]
    )
    let responseData = try JSONSerialization.data(withJSONObject: ["config": configObject])
    client.jsonRPCResponsesByMethod["get_config"] = String(decoding: responseData, as: UTF8.self)
    client.networkInfos = [
        "managed-instance": NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(ipv4_addr: nil, hostname: "managed-mac", peer_id: 7),
            running: true,
            instance_id: instanceID
        ),
    ]

    await store.refreshRuntime()

    #expect(client.jsonRPCCalls.map(\.method) == ["get_config"])
    #expect(store.selectedConfigIsRuntimeManaged)
    #expect(store.selectedConfig?.network_name == remoteConfig.network_name)
    #expect(store.selectedConfig?.peer_urls == remoteConfig.peer_urls)
    #expect(store.selectedConfig?.listener_urls == remoteConfig.listener_urls)
    #expect(store.selectedConfig?.no_tun == remoteConfig.no_tun)
    #expect(store.selectedConfig?.network_secret == nil)
}

@MainActor
@Test func failedConfigServerConfigurationLoadCanBeRetried() async throws {
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)
    store.setConfigurationAuthority(.configServer)
    let instanceID = "11111111-2222-3333-4444-555555555555"
    client.networkInfos = [
        "managed-instance": NetworkInstanceRunningInfo(running: true, instance_id: instanceID),
    ]
    client.jsonRPCError = EasyTierCoreError.operationFailed("RPC unavailable")

    await store.refreshRuntime()

    #expect(store.selectedRuntimeManagedConfiguration == nil)
    #expect(store.selectedRuntimeManagedConfigurationLoadError?.contains("RPC unavailable") == true)

    let recovered = NetworkConfig(instance_id: instanceID, network_name: "managed-network", no_tun: true)
    let configObject = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(recovered)) as? [String: Any]
    )
    let responseData = try JSONSerialization.data(withJSONObject: ["config": configObject])
    client.jsonRPCError = nil
    client.jsonRPCResponsesByMethod["get_config"] = String(decoding: responseData, as: UTF8.self)

    await store.reloadSelectedRuntimeManagedConfiguration()

    #expect(client.jsonRPCCalls.map(\.method) == ["get_config", "get_config"])
    #expect(store.selectedRuntimeManagedConfiguration?.network_name == "managed-network")
    #expect(store.selectedRuntimeManagedConfigurationLoadError == nil)
}

@MainActor
@Test func configurationAuthoritySeparatesManagedSelectionFromPersistedLocalSelection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let client = RecordingToggleClient()
    let storage = EasyTierStorage(baseDirectory: directory)
    let store = EasyTierAppStore(client: client, storage: storage)
    let local = NetworkConfig(instance_id: "local-id", network_name: "local-network")
    store.configs = [local]
    await store.selectConfig(id: local.id)
    store.setConfigurationAuthority(.configServer)

    client.networkInfos = [
        "managed-network": NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "managed-mac", peer_id: 7),
            running: true,
            instance_id: "managed-id"
        ),
    ]
    await store.refreshRuntime()
    await store.selectConfig(id: "managed-id")
    await store.setVPNOnDemandEnabled(true)

    let persisted = try await ApplicationDatabase(
        baseDirectory: directory,
        gatewayFileURL: directory.appending(path: "gateway/config.json"),
        networkSecretStore: MemoryNetworkSecretStore()
    ).loadWorkspace()
    #expect(persisted.configs.map(\.id) == [local.id])
    #expect(persisted.selectedConfigID == local.id)
    #expect(store.selectedConfigID == "managed-id")
    #expect(store.presentedConfigs.map(\.id) == ["managed-id"])

    client.networkInfos = [:]
    await store.refreshRuntime()

    #expect(store.runtimeManagedConfigs.isEmpty)
    #expect(store.selectedConfigID == nil)

    store.setConfigurationAuthority(.local)

    #expect(store.selectedConfigID == local.id)
    #expect(store.presentedConfigs.map(\.id) == [local.id])
}

@MainActor
@Test func runtimeManagedSelectionFollowsNetworkNameWhenInstanceIDIsReissued() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    store.setConfigurationAuthority(.configServer)

    client.networkInfos = [
        "managed-a": NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(ipv4_addr: "10.0.1.1/24", hostname: "a-mac", peer_id: 1),
            running: true,
            instance_id: "a-v1"
        ),
        "managed-b": NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(ipv4_addr: "10.0.2.1/24", hostname: "b-mac", peer_id: 2),
            running: true,
            instance_id: "b-v1"
        ),
    ]
    await store.refreshRuntime()
    await store.selectConfig(id: "b-v1")
    #expect(store.selectedConfigID == "b-v1")

    // Config Server reissues the same networks with new instance ids. The
    // selection must follow the network name instead of jumping elsewhere.
    client.networkInfos = [
        "managed-a": NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(ipv4_addr: "10.0.1.1/24", hostname: "a-mac", peer_id: 1),
            running: true,
            instance_id: "a-v2"
        ),
        "managed-b": NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(ipv4_addr: "10.0.2.1/24", hostname: "b-mac", peer_id: 2),
            running: true,
            instance_id: "b-v2"
        ),
    ]
    await store.refreshRuntime()

    #expect(store.selectedConfigID == "b-v2")
    #expect(store.selectedStatusSnapshot.networkName == "managed-b")
}

@MainActor
@Test func runtimeManagedNetworkRejectsLocalRuntimeAndExportActions() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    store.setConfigurationAuthority(.configServer)
    client.networkInfos = [
        "managed-network": NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "managed-mac", peer_id: 7),
            running: true,
            instance_id: "managed-id"
        ),
    ]
    await store.refreshRuntime()

    await store.toggleSelectedConfigConnection()
    let runOutcome = await store.runSelectedConfig()
    await store.stopSelectedConfig()

    #expect(runOutcome == .none)
    #expect(client.runConfigs.isEmpty)
    #expect(client.stoppedInstanceNames.isEmpty)
    await #expect(throws: EasyTierCoreError.self) {
        _ = try await store.exportSelectedTOML()
    }
}

@MainActor
@Test func configServerRuntimeFeedsExistingTrafficSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    store.setConfigurationAuthority(.configServer)
    store.selectedTab = .view

    func runtimeInfo(txBytes: Int, rxBytes: Int) -> NetworkInstanceRunningInfo {
        NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "managed-mac", peer_id: 7),
            peers: [
                PeerInfo(
                    peer_id: 8,
                    conns: [PeerConnInfo(stats: PeerConnStats(rx_bytes: rxBytes, tx_bytes: txBytes))]
                ),
            ],
            running: true,
            instance_id: "managed-id"
        )
    }

    client.networkInfos = ["managed-network": runtimeInfo(txBytes: 1_000, rxBytes: 2_000)]
    await store.refreshRuntime()
    try await Task.sleep(for: .milliseconds(10))
    client.networkInfos = ["managed-network": runtimeInfo(txBytes: 2_000, rxBytes: 4_000)]
    await store.refreshRuntime()

    #expect(store.selectedConfigIsRuntimeManaged)
    #expect(store.selectedTrafficSnapshot.hasRunningInstance)
    #expect(store.selectedTrafficSnapshot.networkName == "managed-network")
    #expect(store.selectedTrafficSnapshot.samplingPhase == .live)
    #expect(store.selectedTrafficSnapshot.latest?.txBytesPerSecond ?? 0 > 0)
    #expect(store.selectedTrafficSnapshot.latest?.rxBytesPerSecond ?? 0 > 0)
}

@MainActor
@Test func helperPermissionErrorsDoNotBecomeModalLastError() async throws {
    let client = HelperRunErrorClient(
        payload: PrivilegedHelperErrorPayload(
            code: "helperRequiresApproval",
            message: "Approval is pending."
        )
    )
    let config = NetworkConfig(instance_id: "approval-id", network_name: "approval-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()

    #expect(store.lastError?.contains("Approval is pending.") == true)
    #expect(store.lastErrorIsHelperPermission)
    #expect(store.logLines.contains { $0.text.contains("Error:") && $0.text.contains("Approval is pending.") })
}

@MainActor
@Test func helperUnavailableErrorBecomesModalLastError() async throws {
    let client = HelperRunErrorClient(
        payload: PrivilegedHelperErrorPayload(
            code: "helperUnavailable",
            message: "Privileged helper is enabled but is not responding."
        )
    )
    let config = NetworkConfig(instance_id: "helper-down-id", network_name: "helper-down-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()

    #expect(store.lastError?.contains("not responding") == true)
    #expect(!store.lastErrorIsHelperPermission)
}

@MainActor
@Test func retryStartAfterHelperApprovalRunsPendingConfigWhenHelperIsEnabled() async throws {
    let client = RecordingToggleClient()
    let backend = HelperRegistrationBackendSpy(status: .requiresApproval)
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)
    let config = NetworkConfig(instance_id: "pending-approval-id", network_name: "pending-approval-network")
    let secrets = MemoryNetworkSecretStore(secrets: [config.network_name: "pending-secret"])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(
        runtimeClient: client,
        helperRegistration: registration,
        storage: EasyTierStorage(baseDirectory: directory),
        networkSecretStore: secrets
    )

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()
    #expect(client.runConfigs.isEmpty)
    #expect(store.lastErrorIsHelperPermission)
    #expect(secrets.readReasons.count == 1)

    await store.retryStartAfterHelperApproval()
    #expect(client.runConfigs.isEmpty)

    store.handleApplicationDidResignActive()
    backend.status = .enabled
    await store.retryStartAfterHelperApproval()

    #expect(client.runConfigs.map(\.instance_id) == [config.instance_id])
    #expect(client.runConfigs.first?.network_secret == "pending-secret")
    #expect(secrets.readPurposes == [.run])
    #expect(secrets.savePurposes.isEmpty)
}

@MainActor
@Test func enteredSecretSurvivesHelperApprovalThroughKeychain() async throws {
    let client = RecordingToggleClient()
    let backend = HelperRegistrationBackendSpy(status: .requiresApproval)
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)
    let config = NetworkConfig(instance_id: "entered-secret-approval-id", network_name: "approval-network")
    let secrets = MemoryNetworkSecretStore()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(
        runtimeClient: client,
        helperRegistration: registration,
        storage: EasyTierStorage(baseDirectory: directory),
        networkSecretStore: secrets
    )

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let outcome = await store.runSelectedConfig(
        networkSecretInput: .edited("typed-secret")
    )

    #expect(client.runConfigs.isEmpty)
    #expect(secrets.secrets[config.network_name] == "typed-secret")
    #expect(secrets.readReasons.isEmpty)
    #expect(outcome.didPersistEditedSecret)
    #expect(secrets.savePurposes == [.update])

    store.handleApplicationDidResignActive()
    backend.status = .enabled
    await store.retryStartAfterHelperApproval()

    #expect(client.runConfigs.first?.network_secret == "typed-secret")
    #expect(secrets.readPurposes.isEmpty)
    #expect(secrets.savePurposes == [.update])
}

@MainActor
@Test func olderHelperApprovalRetryDoesNotOverwriteNewerPendingConfig() throws {
    let client = RecordingToggleClient()
    let controller = RuntimeSessionController(
        runtimeClient: client,
        helperRegistration: nil,
        systemSleepPreventer: RecordingSystemSleepPreventer()
    )
    let older = NetworkConfig(instance_id: "older-approval-id", network_name: "older-approval")
    let newer = NetworkConfig(instance_id: "newer-approval-id", network_name: "newer-approval")

    controller.setPendingStartAfterApproval(older)
    #expect(controller.takePendingStartAfterApproval() == older)
    controller.setPendingStartAfterApproval(newer)
    controller.restorePendingStartAfterApprovalIfEmpty(older)

    #expect(controller.takePendingStartAfterApproval() == newer)
}

@MainActor
@Test func ensureRegisteredDoesNotReinstallWhenHelperRequiresApproval() async throws {
    let backend = HelperRegistrationBackendSpy(status: .requiresApproval)
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)

    do {
        try await registration.ensureRegistered()
        Issue.record("ensureRegistered should wait for approval")
    } catch let error as PrivilegedHelperError {
        #expect(error == .needsRegistration)
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(registration.state == .requiresApproval)
    #expect(backend.registerCount == 0)
    #expect(backend.unregisterCount == 0)
}

@MainActor
@Test func ensureRegisteredProbesAnAlreadyEnabledHelper() async throws {
    let backend = HelperRegistrationBackendSpy(status: .enabled)
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)

    try await registration.ensureRegistered()

    #expect(backend.probeCount == 1)
    #expect(backend.registerCount == 0)
    #expect(backend.unregisterCount == 0)
    #expect(registration.state == .enabled)
}

@MainActor
@Test func ensureRegisteredReplacesAProtocolMismatchedHelper() async throws {
    let backend = HelperRegistrationBackendSpy(status: .enabled)
    backend.statusAfterRegister = .enabled
    backend.probeErrors = [
        PrivilegedHelperError.helperReported(
            PrivilegedHelperErrorPayload(code: "protocolMismatch", message: "old helper")
        ),
    ]
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)

    try await registration.ensureRegistered()

    #expect(backend.probeCount == 2)
    #expect(backend.unregisterCount == 1)
    #expect(backend.waitAfterUnregisterCount == 1)
    #expect(backend.registerCount == 1)
    #expect(registration.state == .enabled)
}

@MainActor
@Test func ensureRegisteredReplacesAnEnabledHelperWhenTheProbeFails() async throws {
    let backend = HelperRegistrationBackendSpy(status: .enabled)
    backend.statusAfterRegister = .enabled
    backend.probeErrors = [
        PrivilegedHelperError.helperReported(
            PrivilegedHelperErrorPayload(
                code: "helperProbeTimeout",
                message: "old helper did not respond"
            )
        ),
    ]
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)

    try await registration.ensureRegistered()

    #expect(backend.probeCount == 2)
    #expect(backend.unregisterCount == 1)
    #expect(backend.waitAfterUnregisterCount == 1)
    #expect(backend.registerCount == 1)
    #expect(registration.state == .enabled)
}

@MainActor
@Test func ensureRegisteredOnlyAttemptsEnabledHelperRepairOncePerLaunch() async throws {
    let backend = HelperRegistrationBackendSpy(status: .enabled)
    backend.statusAfterRegister = .enabled
    backend.probeError = PrivilegedHelperError.helperReported(
        PrivilegedHelperErrorPayload(
            code: "helperProbeTimeout",
            message: "helper remains unavailable"
        )
    )
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)

    for _ in 0 ..< 2 {
        do {
            try await registration.ensureRegistered()
            Issue.record("ensureRegistered should surface the persistent helper failure")
        } catch {
            // The second call may probe again, but must not mutate the registration again.
        }
    }

    #expect(backend.unregisterCount == 1)
    #expect(backend.waitAfterUnregisterCount == 1)
    #expect(backend.registerCount == 1)
}

@Test func helperBuildCompatibilityDetectsStaleEasyTierAndGatewayBuilds() throws {
    let appInfo: [String: Any] = [
        "CFBundleShortVersionString": "2.4.5",
        "CFBundleVersion": "20260721100346",
        "EasyTierBuildTime": "2026-07-21T10:03:46Z",
        "EasyTierGUICommit": "1e55428b3ab78cf7baa3b135a48a781e1eaee914",
        "EasyTierCoreTag": "v2.4.5",
        "EasyTierCoreCommit": "core-current",
        "GatewayBuildTime": "2026-07-21T10:03:46Z",
        "GatewayVersion": "1.3.2",
        "GatewayCommit": "gateway-current",
    ]
    let bundledEasyTier = try PrivilegedHelperBuildInfo(infoDictionary: appInfo)
    var installedEasyTier = bundledEasyTier
    let bundledGateway = try GatewayHelperBuildInfo(infoDictionary: appInfo)
    var installedGateway = try GatewayHelperBuildInfo(infoDictionary: [
        "CFBundleShortVersionString": "1.3.2",
        "CFBundleVersion": "20260721100346",
        "GatewayBuildTime": "2026-07-21T10:03:46Z",
        "GatewayVersion": "1.3.2",
        "GatewayCommit": "gateway-current",
    ])

    #expect(HelperRegistrationService.modernHelperBuildMatches(
        installed: installedEasyTier,
        bundled: bundledEasyTier
    ))
    #expect(HelperRegistrationService.gatewayHelperBuildMatches(
        installed: installedGateway,
        bundled: bundledGateway
    ))

    installedEasyTier.build = "20260719193734"
    installedGateway.build = "20260719193734"

    #expect(!HelperRegistrationService.modernHelperBuildMatches(
        installed: installedEasyTier,
        bundled: bundledEasyTier
    ))
    #expect(!HelperRegistrationService.gatewayHelperBuildMatches(
        installed: installedGateway,
        bundled: bundledGateway
    ))
}

@Test func xpcCodeSigningRequirementRequiresTheExpectedPeerAndTeam() throws {
    let requirement = try EasyTierXPCCodeSigningRequirements.requirement(
        peerIdentifier: EasyTierPrivilegedHelperConstants.bundleIdentifier,
        teamIdentifier: "TEAM123456",
        allowIdentifierOnly: false
    )

    #expect(requirement.contains(#"identifier "com.kkrainbow.easytier.mac.helper""#))
    #expect(requirement.contains("anchor apple generic"))
    #expect(requirement.contains(#"certificate leaf[subject.OU] = "TEAM123456""#))
    var compiledRequirement: SecRequirement?
    #expect(SecRequirementCreateWithString(requirement as CFString, [], &compiledRequirement) == errSecSuccess)
    #expect(compiledRequirement != nil)
}

@Test func xpcCodeSigningRequirementOnlyAllowsMissingTeamForDebugFallback() throws {
    let fallback = try EasyTierXPCCodeSigningRequirements.requirement(
        peerIdentifier: EasyTierPrivilegedHelperConstants.appBundleIdentifier,
        teamIdentifier: nil,
        allowIdentifierOnly: true
    )

    #expect(fallback == #"identifier "com.kkrainbow.easytier.mac""#)
    #expect(throws: EasyTierXPCCodeSigningRequirementError.self) {
        try EasyTierXPCCodeSigningRequirements.requirement(
            peerIdentifier: EasyTierPrivilegedHelperConstants.appBundleIdentifier,
            teamIdentifier: nil,
            allowIdentifierOnly: false
        )
    }
}

#if DEBUG
@Test func xpcCodeSigningRequirementReadsTheCurrentDebugSignature() throws {
    let requirement = try EasyTierXPCCodeSigningRequirements.requirement(
        forPeerIdentifier: EasyTierPrivilegedHelperConstants.bundleIdentifier
    )

    #expect(requirement.contains(EasyTierPrivilegedHelperConstants.bundleIdentifier))
}
#endif

@MainActor
@Test func ensureRegisteredUsesXPCProbeWhenServiceStatusIsStillNotFound() async throws {
    let backend = HelperRegistrationBackendSpy(status: .notFound)
    backend.statusAfterRegister = .notFound
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)

    try await registration.ensureRegistered()

    #expect(backend.registerCount == 1)
    #expect(backend.probeCount == 1)
    #expect(registration.state == .enabled)
}

@MainActor
@Test func ensureRegisteredClassifiesXPCProbeFailureUsingServiceStatus() async throws {
    let backend = HelperRegistrationBackendSpy(status: .notFound)
    backend.statusAfterRegister = .requiresApproval
    backend.probeError = PrivilegedHelperError.unavailable
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)

    do {
        try await registration.ensureRegistered()
        Issue.record("ensureRegistered should surface the failed helper probe")
    } catch let error as PrivilegedHelperError {
        #expect(error == .needsRegistration)
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(backend.probeCount == 1)
    #expect(registration.state == .requiresApproval)
}
