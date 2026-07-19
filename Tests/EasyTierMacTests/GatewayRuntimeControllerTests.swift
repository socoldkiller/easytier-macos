import EasyTierShared
import Foundation
import Testing
@testable import EasyTierMac

@MainActor
@Test func publishingServiceStartsDerivedConfigurationWhenGatewayIsEnabled() async throws {
    let store = InMemoryGatewayConfigurationStore()
    let client = RecordingGatewayClient()
    let controller = makeController(store: store, client: client)
    await controller.load()
    #expect(!controller.isTLSConfigured)

    let draft = try await controller.createDraft(
        networkConfigID: "network-a",
        targetPeerID: "peer-a",
        targetHostname: "a",
        magicDNSSuffix: "et.net.",
        serviceLabel: "abc",
        targetPort: 3_000
    )
    try await controller.configureACME(
        contactEmail: "ops@example.com",
        termsOfServiceAgreed: true
    )
    #expect(controller.isTLSConfigured)
    #expect(controller.acmeConfiguration?.contactEmail == "ops@example.com")
    await controller.reconcileTopology(
        networkConfigID: "network-a",
        allowedIPv4CIDR: "10.0.0.0/24",
        magicDNSSuffix: "et.net.",
        hostnamesByPeerID: ["peer-a": "a"]
    )
    try await controller.setServiceEnabled(true, serviceID: draft.id)
    #expect(!controller.desiredEnabled)
    #expect(await client.callNames().isEmpty)

    try await controller.setGatewayEnabled(true)

    let runtime = try #require(await client.lastStartedConfiguration())
    let route = try #require(runtime.routes.first)
    let saved = try #require(await store.currentState())
    #expect(controller.desiredEnabled)
    #expect(controller.status.state == .running)
    #expect(saved.services.first?.desiredEnabled == true)
    #expect(saved.gatewayEnabled)
    #expect(runtime.localDomains == ["abc.a.et.net"])
    #expect(route.domain == "abc.a.et.net")
    #expect(route.upstream.url == "http://a.et.net:3000")
    #expect(route.upstream.allowedIPv4CIDR == "10.0.0.0/24")
    #expect(await client.callNames() == [
        "retain:false",
        "start",
        "status",
    ])
}

@MainActor
@Test func gatewayCanRunWithoutPublishedServicesOrACMEConfiguration() async throws {
    let store = InMemoryGatewayConfigurationStore()
    let client = RecordingGatewayClient()
    let controller = makeController(store: store, client: client)
    await controller.load()

    try await controller.setGatewayEnabled(true)

    let runtime = try #require(await client.lastStartedConfiguration())
    #expect(controller.desiredEnabled)
    #expect(controller.status.state == .running)
    #expect(runtime.certificates.isEmpty)
    #expect(runtime.routes.isEmpty)
    #expect(runtime.localDomains.isEmpty)
    #expect(!runtime.acme.termsOfServiceAgreed)
    #expect(await client.callNames() == ["retain:false", "start", "status"])
}

@MainActor
@Test func disablingTheLastServiceKeepsTheGatewayRuntimeRunning() async throws {
    let state = gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: true)
    let store = InMemoryGatewayConfigurationStore(state: state)
    let client = RecordingGatewayClient()
    let controller = makeController(store: store, client: client)
    await controller.load()
    await controller.reconcile()

    try await controller.setServiceEnabled(false, serviceID: "service-a")

    let saved = try #require(await store.currentState())
    #expect(saved.services.count == 1)
    #expect(saved.services[0].desiredEnabled == false)
    #expect(saved.gatewayEnabled)
    #expect(saved.publishingNetworkConfigID == "network-a")
    #expect(controller.status.state == .running)
    let applied = try #require(await client.lastAppliedConfiguration())
    #expect(applied.certificates.isEmpty)
    #expect(applied.routes.isEmpty)
    #expect(await client.callNames() == [
        "retain:false",
        "start",
        "status",
        "retain:false",
        "apply",
        "status",
    ])
}

@MainActor
@Test func disablingGatewayStopsRuntimeWithoutChangingServiceIntent() async throws {
    let store = InMemoryGatewayConfigurationStore(
        state: gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: true)
    )
    let client = RecordingGatewayClient()
    let controller = makeController(store: store, client: client)
    await controller.load()
    await controller.reconcile()

    try await controller.setGatewayEnabled(false)

    let saved = try #require(await store.currentState())
    #expect(!saved.gatewayEnabled)
    #expect(saved.services.first?.desiredEnabled == true)
    #expect(controller.status.state == .stopped)
    #expect(await client.callNames().suffix(1) == ["stop"])
}

@MainActor
@Test func portAndTopologyChangesUpdateOnlyTheInternalRoute() async throws {
    let store = InMemoryGatewayConfigurationStore(
        state: gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: true)
    )
    let client = RecordingGatewayClient()
    let controller = makeController(store: store, client: client)
    await controller.load()
    await controller.reconcile()

    try await controller.updatePort(serviceID: "service-a", port: 8_443)
    await controller.reconcileTopology(
        networkConfigID: "network-a",
        allowedIPv4CIDR: "10.0.0.0/24",
        magicDNSSuffix: "mesh.net.",
        hostnamesByPeerID: ["peer-a": "renamed"]
    )

    let savedService = try #require(await store.currentState()?.services.first)
    let runtime = try #require(await client.lastAppliedConfiguration())
    #expect(savedService.publicHostname == "abc.a.et.net")
    #expect(savedService.targetDomain == "renamed.mesh.net")
    #expect(savedService.targetPort == 8_443)
    #expect(runtime.routes.first?.domain == "abc.a.et.net")
    #expect(runtime.routes.first?.upstream.url == "http://renamed.mesh.net:8443")
    #expect(await client.callNames().filter { $0 == "apply" }.count == 2)
}

@MainActor
@Test func lifecycleRetentionLeavesAnEnabledGatewayRunning() async throws {
    let store = InMemoryGatewayConfigurationStore(
        state: gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: true)
    )
    let client = RecordingGatewayClient()
    let controller = makeController(store: store, client: client)
    await controller.load()
    await controller.reconcile()

    await controller.stopForLifecycle(retainRuntime: true)

    let calls = await client.callNames()
    #expect(controller.status.state == .running)
    #expect(calls.suffix(1) == ["retain:true"])
    #expect(!calls.contains("stop"))
}

@MainActor
private func makeController(
    store: any GatewayConfigurationStoring,
    client: any GatewayClient
) -> GatewayRuntimeController {
    GatewayRuntimeController(
        client: client,
        configurationStore: store,
        helperRegistration: nil
    )
}

private actor RecordingGatewayClient: GatewayClient {
    private var calls: [String] = []
    private var isRunning = false
    private var startedConfigurations: [GatewayConfiguration] = []
    private var appliedConfigurations: [GatewayConfiguration] = []
    func start(configuration: GatewayConfiguration) {
        calls.append("start")
        startedConfigurations.append(configuration)
        isRunning = true
    }

    func apply(configuration: GatewayConfiguration) {
        calls.append("apply")
        appliedConfigurations.append(configuration)
    }

    func stop() {
        calls.append("stop")
        isRunning = false
    }

    func status() -> GatewayStatus {
        calls.append("status")
        var status = GatewayStatus.stopped
        status.state = isRunning ? .running : .stopped
        return status
    }

    func requestRenewal(certificateID: String?) {
        calls.append("renew")
    }

    func setRetainsRuntimeAfterDisconnect(_ retainsRuntime: Bool) {
        calls.append("retain:\(retainsRuntime)")
    }

    func callNames() -> [String] { calls }
    func lastStartedConfiguration() -> GatewayConfiguration? { startedConfigurations.last }
    func lastAppliedConfiguration() -> GatewayConfiguration? { appliedConfigurations.last }
}

private actor InMemoryGatewayConfigurationStore: GatewayConfigurationStoring {
    private var state: GatewayPersistedState?

    init(state: GatewayPersistedState? = nil) {
        self.state = state
    }

    func load() -> GatewayPersistedState? {
        state
    }

    func save(_ state: GatewayPersistedState) {
        self.state = state
    }

    func currentState() -> GatewayPersistedState? {
        state
    }
}

private func gatewayControllerTestState(
    gatewayEnabled: Bool,
    serviceEnabled: Bool
) -> GatewayPersistedState {
    GatewayPersistedState(
        gatewayEnabled: gatewayEnabled,
        acmeAccount: GatewayACMEConfiguration(
            directory: .letsencryptProduction,
            contactEmail: "ops@example.com",
            termsOfServiceAgreed: true
        ),
        publishingNetworkConfigID: "network-a",
        lastKnownNetworkIPv4CIDR: "10.0.0.0/24",
        services: [
            GatewayPublishedService(
                id: "service-a",
                networkConfigID: "network-a",
                targetPeerID: "peer-a",
                publicNodeLabel: "a",
                publicDNSSuffix: "et.net.",
                lastKnownTargetHostname: "a",
                lastKnownMagicDNSSuffix: "et.net.",
                serviceLabel: "abc",
                publicHostname: "abc.a.et.net",
                targetPort: 3_000,
                desiredEnabled: serviceEnabled
            ),
        ]
    )
}
