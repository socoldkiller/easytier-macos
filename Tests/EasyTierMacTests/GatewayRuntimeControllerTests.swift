import EasyTierShared
import Foundation
import Testing
@testable import EasyTierMac

@MainActor
@Test func publishingServiceConfiguresAutomaticHTTPSAndStartsGateway() async throws {
    let store = InMemoryGatewayConfigurationStore()
    let client = RecordingGatewayClient()
    let controller = makeController(store: store, client: client)
    await controller.load()
    #expect(!controller.isAutomaticHTTPSReady)
    await controller.reconcileTopology(
        networkConfigID: "network-a",
        allowedIPv4CIDR: "10.0.0.0/24",
        magicDNSSuffix: "et.net.",
        hostnamesByPeerID: ["peer-a": "a"]
    )
    let service = try await controller.createService(
        networkConfigID: "network-a",
        targetPeerID: "peer-a",
        targetHostname: "a",
        magicDNSSuffix: "et.net.",
        serviceLabel: "abc",
        targetPort: 3_000,
        contactEmail: " ops@example.com "
    )

    let runtime = try #require(await client.lastStartedConfiguration())
    let route = try #require(runtime.routes.first)
    let saved = try #require(await store.currentState())
    #expect(controller.desiredEnabled)
    #expect(controller.isAutomaticHTTPSReady)
    #expect(controller.status.state == .running)
    #expect(saved.acmeAccount?.contactEmail == "ops@example.com")
    #expect(saved.acmeAccount?.termsOfServiceAgreed == true)
    #expect(saved.services.first?.id == service.id)
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
@Test func publishingWithoutCertificateEmailDoesNotPersistPartialState() async throws {
    let store = InMemoryGatewayConfigurationStore()
    let client = RecordingGatewayClient()
    let controller = makeController(store: store, client: client)
    await controller.load()
    await controller.reconcileTopology(
        networkConfigID: "network-a",
        allowedIPv4CIDR: "10.0.0.0/24",
        magicDNSSuffix: "et.net.",
        hostnamesByPeerID: ["peer-a": "a"]
    )

    await #expect(throws: GatewayConfigurationValidationError.self) {
        try await controller.createService(
            networkConfigID: "network-a",
            targetPeerID: "peer-a",
            targetHostname: "a",
            magicDNSSuffix: "et.net.",
            serviceLabel: "abc",
            targetPort: 3_000
        )
    }

    #expect(await store.currentState() == nil)
    #expect(controller.acmeConfiguration == nil)
    #expect(controller.services.isEmpty)
    #expect(!controller.desiredEnabled)
    #expect(await client.callNames().isEmpty)
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
@Test func newDNS01ServicePersistsAndAppliesOnlyItsFinalPolicy() async throws {
    let configurationStore = InMemoryGatewayConfigurationStore()
    let credentialStore = InMemoryGatewayCredentialStore()
    let client = RecordingGatewayClient()
    let controller = GatewayRuntimeController(
        client: client,
        configurationStore: configurationStore,
        credentialStore: credentialStore,
        helperRegistration: nil
    )
    await controller.load()
    try await controller.configureAutomaticHTTPS(contactEmail: "ops@example.com")
    await controller.reconcileTopology(
        networkConfigID: "network-a",
        allowedIPv4CIDR: "10.0.0.10/24",
        magicDNSSuffix: "et.net.",
        hostnamesByPeerID: ["peer-a": "a"]
    )
    let descriptor = GatewayDNSCredentialDescriptor(
        id: "cloudflare-main",
        provider: .cloudflare,
        label: "Cloudflare Main"
    )
    try await controller.saveDNSCredential(
        descriptor: descriptor,
        secret: .cloudflare(apiToken: "test-token")
    )

    let service = try await controller.createService(
        networkConfigID: "network-a",
        targetPeerID: "peer-a",
        targetHostname: "a",
        magicDNSSuffix: "et.net.",
        serviceLabel: "dns",
        targetPort: 3_000,
        certificatePolicy: GatewayCertificatePolicy(
            authority: .zeroSSL,
            challenge: .dns01(credentialID: descriptor.id)
        )
    )

    let saved = try #require(await configurationStore.currentState())
    #expect(saved.services == [service])
    #expect(saved.lastKnownNetworkIPv4CIDR == "10.0.0.10/24")
    #expect(saved.services[0].certificatePolicy.authority == .zeroSSL)
    #expect(saved.services[0].certificatePolicy.challenge == .dns01(credentialID: descriptor.id))
    #expect(saved.gatewayEnabled)
    let expectedRuntime = try GatewayConfigurationFactory.makeRuntimeConfiguration(from: saved)
    #expect(expectedRuntime.certificates.first?.authority == .zeroSSL)
    #expect(
        expectedRuntime.certificates.first?.challenge
            == .dns01(
                GatewayDNS01Configuration(
                    provider: .cloudflare,
                    credentialID: descriptor.id,
                    credentialRevision: descriptor.revision
                )
            )
    )

    let runtime = try #require(await client.lastStartedConfiguration())
    let certificate = try #require(runtime.certificates.first)
    #expect(certificate.authority == .zeroSSL)
    #expect(
        certificate.challenge
            == .dns01(
                GatewayDNS01Configuration(
                    provider: .cloudflare,
                    credentialID: descriptor.id,
                    credentialRevision: descriptor.revision
                )
            )
    )
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
@Test func failedApplyKeepsDesiredPolicyAndReportsAppliedDivergence() async throws {
    let state = gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: true)
    let configurationStore = InMemoryGatewayConfigurationStore(state: state)
    let client = RecordingGatewayClient(applyFailures: 10)
    let controller = makeController(store: configurationStore, client: client)
    await controller.load()
    await controller.reconcile()
    let initiallyApplied = try #require(controller.status.appliedDeployment)

    try await controller.updateCertificatePolicy(
        serviceID: "service-a",
        policy: GatewayCertificatePolicy(
            authority: .zeroSSL,
            challenge: .http01
        )
    )

    let saved = try #require(await configurationStore.currentState())
    #expect(saved.services[0].certificatePolicy.authority == .zeroSSL)
    #expect(controller.status.appliedDeployment == initiallyApplied)
    #expect(controller.convergence.phase == .retryScheduled)
    #expect(controller.convergence.desired != initiallyApplied)
    #expect(controller.convergence.applied == initiallyApplied)
    #expect(controller.convergence.isServingPreviousConfiguration)
    await controller.stopForLifecycle()
}

@MainActor
@Test func ambiguousApplyFailureConvergesWhenStatusProvesTheDeployment() async throws {
    let state = gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: true)
    let configurationStore = InMemoryGatewayConfigurationStore(state: state)
    let client = RecordingGatewayClient(applyThenThrowOnce: true)
    let controller = makeController(store: configurationStore, client: client)
    await controller.load()
    await controller.reconcile()

    try await controller.updatePort(serviceID: "service-a", port: 4_000)

    let saved = try #require(await configurationStore.currentState())
    #expect(saved.services[0].targetPort == 4_000)
    #expect(controller.convergence.phase == .converged)
    #expect(controller.convergence.desired == controller.status.appliedDeployment)
    #expect(await client.callNames().filter { $0 == "apply" }.count == 1)
    await controller.stopForLifecycle()
}

@MainActor
@Test func missingDNSCredentialBlocksApplyWithoutChangingDesiredPolicy() async throws {
    var state = gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: true)
    let descriptor = GatewayDNSCredentialDescriptor(
        id: "missing-cloudflare",
        provider: .cloudflare,
        label: "Missing Cloudflare"
    )
    state.dnsCredentials = [descriptor]
    state.services[0].certificatePolicy = GatewayCertificatePolicy(
        authority: .zeroSSL,
        challenge: .dns01(credentialID: descriptor.id)
    )
    let configurationStore = InMemoryGatewayConfigurationStore(state: state)
    let client = RecordingGatewayClient()
    let controller = GatewayRuntimeController(
        client: client,
        configurationStore: configurationStore,
        credentialStore: InMemoryGatewayCredentialStore(),
        helperRegistration: nil
    )

    await controller.load()
    await controller.reconcile()

    #expect(controller.convergence.phase == .blocked)
    #expect(controller.convergence.applied == nil)
    #expect(controller.persistedState?.services[0].certificatePolicy == state.services[0].certificatePolicy)
    #expect(controller.lastError?.contains("is missing") == true)
    #expect(await client.callNames() == ["status"])
}

@MainActor
@Test func serviceCanBeEnabledWhileMagicDNSIsLoading() async throws {
    let configurationStore = InMemoryGatewayConfigurationStore(
        state: gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: false)
    )
    let client = RecordingGatewayClient()
    let controller = GatewayRuntimeController(
        client: client,
        configurationStore: configurationStore,
        helperRegistration: nil,
        magicDNSResolver: FixedMagicDNSResolver(addresses: [])
    )
    let appStore = EasyTierAppStore(client: PreviewEasyTierCoreClient(), storage: .isolatedForTesting())
    var config = NetworkConfig(instance_id: "network-a", network_name: "mesh")
    config.enable_magic_dns = true
    appStore.configs = [config]
    appStore.selectedConfigID = config.instance_id
    controller.bind(to: appStore)
    await controller.load()

    await waitUntil { controller.magicDNSState == .loading }
    try await controller.setServiceEnabled(true, serviceID: "service-a")

    let saved = try #require(await configurationStore.currentState())
    #expect(saved.services.first?.desiredEnabled == true)
    #expect(controller.magicDNSState == .loading)
    #expect((await client.lastAppliedConfiguration())?.routes.first?.upstream.availability == .waiting)
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
@Test func changingServiceTargetPreservesPublicDomainAndAppliesNewProxyRoute() async throws {
    let store = InMemoryGatewayConfigurationStore(
        state: gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: true)
    )
    let client = RecordingGatewayClient()
    let controller = makeController(store: store, client: client)
    await controller.load()
    await controller.reconcile()

    try await controller.updateService(
        serviceID: "service-a",
        targetPeerID: "peer-b",
        targetHostname: "beta",
        magicDNSSuffix: "mesh.net.",
        port: 8_080
    )

    let savedService = try #require(await store.currentState()?.services.first)
    let runtime = try #require(await client.lastAppliedConfiguration())
    #expect(savedService.publicHostname == "abc.a.et.net")
    #expect(savedService.targetPeerID == "peer-b")
    #expect(savedService.targetDomain == "beta.mesh.net")
    #expect(savedService.targetPort == 8_080)
    #expect(runtime.routes.first?.domain == "abc.a.et.net")
    #expect(runtime.routes.first?.upstream.url == "http://beta.mesh.net:8080")
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
@Test func magicDNSRestartKeepsRoutesLoadingThenPausesWhenDisabled() async throws {
    var state = gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: true)
    state.services[0].targetPeerID = "20"
    let configurationStore = InMemoryGatewayConfigurationStore(
        state: state
    )
    let client = RecordingGatewayClient()
    let resolver = MappingMagicDNSResolver(addressesByHostname: [
        "a.et.net": ["10.0.0.20"],
        "local.et.net": ["10.0.0.10"],
    ])
    let controller = GatewayRuntimeController(
        client: client,
        configurationStore: configurationStore,
        helperRegistration: nil,
        magicDNSResolver: resolver
    )
    let appStore = EasyTierAppStore(client: PreviewEasyTierCoreClient(), storage: .isolatedForTesting())
    var config = NetworkConfig(instance_id: "network-a", network_name: "mesh")
    config.enable_magic_dns = true
    appStore.configs = [config]
    appStore.selectedConfigID = config.instance_id
    controller.bind(to: appStore)
    await controller.load()

    await waitUntil { controller.magicDNSState == .loading }
    await waitUntil { await client.lastStartedConfiguration() != nil }
    #expect((await client.lastStartedConfiguration())?.routes.first?.upstream.availability == .waiting)
    #expect(controller.servicesVisible)

    let detail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(
            virtual_ipv4: IPv4InetValue(rawValue: "10.0.0.10/24"),
            hostname: "local",
            peer_id: 10
        ),
        peer_route_pairs: [
            PeerRoutePair(
                route: Route(
                    peer_id: 20,
                    ipv4_addr: IPv4InetValue(rawValue: "10.0.0.20/24"),
                    cost: 1,
                    hostname: "a"
                ),
                peer: PeerInfo(peer_id: 20)
            ),
        ],
        running: true,
        applied_magic_dns_enabled: true,
        applied_magic_dns_suffix: "et.net.",
        instance_id: config.instance_id
    )
    appStore.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: detail
        ),
    ]
    appStore.runtimeDetails = [config.network_name: detail]

    await waitUntil {
        guard controller.magicDNSState == .ready else { return false }
        return (await client.lastAppliedConfiguration())?
            .routes.first?.upstream.availability == .ready
    }
    #expect(controller.appliedMagicDNSSuffix == "et.net.")
    #expect((await client.lastAppliedConfiguration())?.routes.first?.upstream.availability == .ready)

    config.enable_magic_dns = false
    appStore.configs = [config]
    await waitUntil { controller.magicDNSState == .disabled && controller.status.state == .stopped }
    #expect(controller.desiredEnabled)
    #expect(!controller.servicesVisible)
}

@MainActor
@Test func networkRestartReappliesReadyRouteWithoutTogglingService() async throws {
    var state = gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: true)
    state.services[0].targetPeerID = "20"
    state.services[0].targetInstanceID = "target-instance"
    let configurationStore = InMemoryGatewayConfigurationStore(state: state)
    let client = RecordingGatewayClient()
    let resolver = MappingMagicDNSResolver(addressesByHostname: [
        "a.et.net": ["10.0.0.20"],
    ])
    let controller = GatewayRuntimeController(
        client: client,
        configurationStore: configurationStore,
        helperRegistration: nil,
        magicDNSResolver: resolver
    )
    let appStore = EasyTierAppStore(client: PreviewEasyTierCoreClient(), storage: .isolatedForTesting())
    var config = NetworkConfig(instance_id: "network-a", network_name: "mesh")
    config.enable_magic_dns = true
    appStore.configs = [config]
    appStore.selectedConfigID = config.instance_id

    let initialDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(
            virtual_ipv4: IPv4InetValue(rawValue: "10.0.0.10/24"),
            hostname: "local",
            peer_id: 10
        ),
        peer_route_pairs: [
            gatewayTestPeerRoute(
                peerID: 20,
                ipv4: "10.0.0.20/24",
                hostname: "a",
                instanceID: "target-instance"
            ),
        ],
        running: true,
        applied_magic_dns_enabled: true,
        applied_magic_dns_suffix: "et.net.",
        instance_id: config.instance_id
    )
    appStore.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: initialDetail
        ),
    ]
    appStore.runtimeDetails = [config.network_name: initialDetail]
    controller.bind(to: appStore)
    await controller.load()

    await waitUntil {
        guard controller.magicDNSState == .ready else { return false }
        let applied = await client.lastAppliedConfiguration()
        let started = await client.lastStartedConfiguration()
        return (applied ?? started)?.routes.first?.upstream.availability == .ready
    }

    appStore.instances = []
    appStore.runtimeDetails = [:]

    await waitUntil {
        guard controller.magicDNSState == .loading else { return false }
        return (await client.lastAppliedConfiguration())?
            .routes.first?.upstream.availability == .waiting
    }

    let restartedDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(
            virtual_ipv4: IPv4InetValue(rawValue: "10.0.0.10/24"),
            hostname: "local",
            peer_id: 11
        ),
        peer_route_pairs: [
            gatewayTestPeerRoute(
                peerID: 21,
                ipv4: "10.0.0.20/24",
                hostname: "a",
                instanceID: "target-instance"
            ),
        ],
        running: true,
        applied_magic_dns_enabled: true,
        applied_magic_dns_suffix: "et.net.",
        instance_id: config.instance_id
    )
    appStore.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: restartedDetail
        ),
    ]
    appStore.runtimeDetails = [config.network_name: restartedDetail]

    await waitUntil {
        guard controller.magicDNSState == .ready,
              let savedService = await configurationStore.currentState()?.services.first,
              savedService.targetPeerID == "21"
        else { return false }
        return (await client.lastAppliedConfiguration())?
            .routes.first?.upstream.availability == .ready
    }

    let savedService = try #require(await configurationStore.currentState()?.services.first)
    #expect(savedService.desiredEnabled)
    #expect(savedService.targetPeerID == "21")
    #expect(savedService.targetInstanceID == "target-instance")
    #expect((await client.lastAppliedConfiguration())?.routes.first?.upstream.expectedIPv4 == "10.0.0.20")
    #expect(controller.status.state == .running)
}

@MainActor
@Test func resolvingRoutesUseFastStatusPolling() throws {
    var status = GatewayStatus.stopped
    status.state = .running
    status.routes = [
        GatewayRouteStatus(
            domain: "abc.a.et.net",
            upstream: "http://a.et.net:3000",
            resolvedAddresses: [],
            certificateID: "service-a",
            resolutionState: .resolving
        ),
    ]

    #expect(GatewayRuntimeController.statusPollingInterval(for: status) == .seconds(1))
}

@MainActor
@Test func routeConvergenceInterruptsAnExistingSlowPollingCycle() async throws {
    var readyStatus = GatewayStatus.stopped
    readyStatus.state = .running
    readyStatus.routes = [gatewayTestRouteStatus(state: .ready)]

    var resolvingStatus = readyStatus
    resolvingStatus.routes = [gatewayTestRouteStatus(state: .resolving)]

    let configurationStore = InMemoryGatewayConfigurationStore(
        state: gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: true)
    )
    let client = SequencedStatusGatewayClient(statuses: [
        readyStatus,
        resolvingStatus,
        readyStatus,
    ])
    let controller = GatewayRuntimeController(
        client: client,
        configurationStore: configurationStore,
        helperRegistration: nil
    )

    await controller.load()
    await controller.reconcile()
    #expect(controller.status.routes.first?.resolutionState == .ready)

    try await controller.updatePort(serviceID: "service-a", port: 3_001)
    #expect(controller.status.routes.first?.resolutionState == .resolving)

    await waitUntil {
        controller.status.routes.first?.resolutionState == .ready
    }
    #expect(controller.status.routes.first?.resolutionState == .ready)

    await controller.stopForLifecycle()
}

@MainActor
@Test func stableHostnameCaseDoesNotRewriteGatewayConfiguration() async throws {
    var state = gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: true)
    state.services[0].targetPeerID = "20"
    state.services[0].targetInstanceID = "target-instance"
    state.services[0].lastKnownTargetHostname = "istoreos"
    let configurationStore = InMemoryGatewayConfigurationStore(state: state)
    let client = RecordingGatewayClient()
    let resolver = MappingMagicDNSResolver(addressesByHostname: [
        "iStoreOS.et.net": ["10.0.0.20"],
        "local.et.net": ["10.0.0.10"],
    ])
    let controller = GatewayRuntimeController(
        client: client,
        configurationStore: configurationStore,
        helperRegistration: nil,
        magicDNSResolver: resolver
    )
    let appStore = EasyTierAppStore(client: PreviewEasyTierCoreClient(), storage: .isolatedForTesting())
    var config = NetworkConfig(instance_id: "network-a", network_name: "mesh")
    config.enable_magic_dns = true
    appStore.configs = [config]
    appStore.selectedConfigID = config.instance_id
    let detail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(
            virtual_ipv4: IPv4InetValue(rawValue: "10.0.0.10/24"),
            hostname: "local",
            peer_id: 10
        ),
        peer_route_pairs: [
            gatewayTestPeerRoute(
                peerID: 20,
                ipv4: "10.0.0.20/24",
                hostname: "iStoreOS",
                instanceID: "target-instance"
            ),
        ],
        running: true,
        applied_magic_dns_enabled: true,
        applied_magic_dns_suffix: "et.net.",
        instance_id: config.instance_id
    )
    appStore.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: detail
        ),
    ]
    appStore.runtimeDetails = [config.network_name: detail]
    controller.bind(to: appStore)
    await controller.load()

    await waitUntil { controller.magicDNSState == .ready }
    let initialResolveCount = await resolver.numberOfResolutions()
    let initialSaveCount = await configurationStore.numberOfSaves()

    controller.environmentDidChange(store: appStore)
    await waitUntil {
        await resolver.numberOfResolutions() > initialResolveCount
    }
    try await Task.sleep(for: .milliseconds(50))

    #expect(await configurationStore.numberOfSaves() == initialSaveCount)
    #expect(await configurationStore.currentState()?.services.first?.lastKnownTargetHostname == "istoreos")
}

@MainActor
@Test func resolvedServiceUpstreamMakesMagicDNSReadyWhenAppliedMetadataIsMissing() async throws {
    var state = gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: true)
    state.services[0].targetPeerID = "20"
    let configurationStore = InMemoryGatewayConfigurationStore(
        state: state
    )
    let client = RecordingGatewayClient()
    let resolver = MappingMagicDNSResolver(addressesByHostname: [
        "a.et.net": ["10.0.0.20"],
    ])
    let controller = GatewayRuntimeController(
        client: client,
        configurationStore: configurationStore,
        helperRegistration: nil,
        magicDNSResolver: resolver
    )
    let appStore = EasyTierAppStore(client: PreviewEasyTierCoreClient(), storage: .isolatedForTesting())
    var config = NetworkConfig(instance_id: "network-a", network_name: "mesh")
    config.enable_magic_dns = true
    appStore.configs = [config]
    appStore.selectedConfigID = config.instance_id

    let detail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(
            virtual_ipv4: IPv4InetValue(rawValue: "10.0.0.10/24"),
            hostname: "local",
            peer_id: 10
        ),
        peer_route_pairs: [
            PeerRoutePair(
                route: Route(
                    peer_id: 20,
                    ipv4_addr: IPv4InetValue(rawValue: "10.0.0.20/24"),
                    cost: 1,
                    hostname: "a"
                ),
                peer: PeerInfo(peer_id: 20)
            ),
        ],
        running: true,
        instance_id: config.instance_id
    )
    appStore.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: detail
        ),
    ]
    appStore.runtimeDetails = [config.network_name: detail]
    controller.bind(to: appStore)
    await controller.load()

    await waitUntil {
        guard controller.magicDNSState == .ready else { return false }
        let applied = await client.lastAppliedConfiguration()
        let started = await client.lastStartedConfiguration()
        return (applied ?? started)?.routes.first?.upstream.availability == .ready
    }
    #expect(controller.magicDNSState == .ready)

    let appliedRuntime = await client.lastAppliedConfiguration()
    let startedRuntime = await client.lastStartedConfiguration()
    let runtime = try #require(appliedRuntime ?? startedRuntime)
    let upstream = try #require(runtime.routes.first?.upstream)
    #expect(upstream.availability == .ready)
    #expect(upstream.expectedIPv4 == "10.0.0.20")
}

@MainActor
@Test func mismatchedServiceDoesNotKeepAnExactServiceInWaiting() async throws {
    var state = gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: true)
    state.services[0].targetPeerID = "20"
    state.services.append(
        GatewayPublishedService(
            id: "service-b",
            networkConfigID: "network-a",
            targetPeerID: "30",
            publicNodeLabel: "b",
            publicDNSSuffix: "et.net.",
            lastKnownTargetHostname: "b",
            lastKnownMagicDNSSuffix: "et.net.",
            serviceLabel: "def",
            publicHostname: "def.b.et.net",
            targetPort: 8_080,
            desiredEnabled: true
        )
    )
    let configurationStore = InMemoryGatewayConfigurationStore(state: state)
    let client = RecordingGatewayClient()
    let resolver = MappingMagicDNSResolver(addressesByHostname: [
        "a.et.net": ["10.0.0.20"],
        "b.et.net": ["10.0.0.99"],
    ])
    let controller = GatewayRuntimeController(
        client: client,
        configurationStore: configurationStore,
        helperRegistration: nil,
        magicDNSResolver: resolver
    )
    let appStore = EasyTierAppStore(client: PreviewEasyTierCoreClient(), storage: .isolatedForTesting())
    var config = NetworkConfig(instance_id: "network-a", network_name: "mesh")
    config.enable_magic_dns = true
    appStore.configs = [config]
    appStore.selectedConfigID = config.instance_id

    let detail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(
            virtual_ipv4: IPv4InetValue(rawValue: "10.0.0.10/24"),
            hostname: "local",
            peer_id: 10
        ),
        peer_route_pairs: [
            gatewayTestPeerRoute(peerID: 20, ipv4: "10.0.0.20/24", hostname: "a"),
            gatewayTestPeerRoute(peerID: 30, ipv4: "10.0.0.30/24", hostname: "b"),
        ],
        running: true,
        instance_id: config.instance_id
    )
    appStore.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: detail
        ),
    ]
    appStore.runtimeDetails = [config.network_name: detail]
    controller.bind(to: appStore)
    await controller.load()

    await waitUntil {
        guard controller.magicDNSState(for: "service-a") == .ready,
              controller.magicDNSState(for: "service-b")
                  == .mismatch(expected: "10.0.0.30", resolved: ["10.0.0.99"])
        else { return false }
        let applied = await client.lastAppliedConfiguration()
        let started = await client.lastStartedConfiguration()
        guard let runtime = applied ?? started else { return false }
        let routes = Dictionary(uniqueKeysWithValues: runtime.routes.map { ($0.certificateID, $0) })
        return routes["service-a"]?.upstream.availability == .ready
            && routes["service-b"]?.upstream.availability == .unavailable
    }

    let appliedRuntime = await client.lastAppliedConfiguration()
    let startedRuntime = await client.lastStartedConfiguration()
    let runtime = try #require(appliedRuntime ?? startedRuntime)
    let routes = Dictionary(uniqueKeysWithValues: runtime.routes.map { ($0.certificateID, $0) })
    #expect(routes["service-a"]?.upstream.availability == .ready)
    #expect(routes["service-a"]?.upstream.expectedIPv4 == "10.0.0.20")
    #expect(routes["service-b"]?.upstream.availability == .unavailable)
    #expect(routes["service-b"]?.upstream.expectedIPv4 == nil)
}

@MainActor
@Test func readyRouteApplyRetriesAfterTransientCancellation() async throws {
    var state = gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: true)
    state.services[0].targetPeerID = "20"
    state.services[0].targetInstanceID = "target-instance"
    let configurationStore = InMemoryGatewayConfigurationStore(state: state)
    let client = RecordingGatewayClient(readyApplyFailures: 1)
    let resolver = MutableMagicDNSResolver()
    let controller = GatewayRuntimeController(
        client: client,
        configurationStore: configurationStore,
        helperRegistration: nil,
        magicDNSResolver: resolver
    )
    let appStore = EasyTierAppStore(client: PreviewEasyTierCoreClient(), storage: .isolatedForTesting())
    var config = NetworkConfig(instance_id: "network-a", network_name: "mesh")
    config.enable_magic_dns = true
    appStore.configs = [config]
    appStore.selectedConfigID = config.instance_id
    let detail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(
            virtual_ipv4: IPv4InetValue(rawValue: "10.0.0.10/24"),
            hostname: "local",
            peer_id: 10
        ),
        peer_route_pairs: [
            gatewayTestPeerRoute(
                peerID: 20,
                ipv4: "10.0.0.20/24",
                hostname: "a",
                instanceID: "target-instance"
            ),
        ],
        running: true,
        applied_magic_dns_enabled: true,
        applied_magic_dns_suffix: "et.net.",
        instance_id: config.instance_id
    )
    appStore.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: detail
        ),
    ]
    appStore.runtimeDetails = [config.network_name: detail]
    controller.bind(to: appStore)
    await controller.load()

    await waitUntil {
        (await client.lastStartedConfiguration())?.routes.first?.upstream.availability == .waiting
    }
    await resolver.setAddresses(["10.0.0.20"], for: "a.et.net")

    await waitUntil {
        await client.successfulReadyApplyCount() == 1
    }

    #expect(await client.readyApplyAttemptCount() == 2)
    #expect((await client.lastAppliedConfiguration())?.routes.first?.upstream.availability == .ready)
    #expect(controller.status.state == .running)
}

@MainActor
@Test func legacyLocalTargetMigratesAndTracksLaterPeerIDChanges() async throws {
    var state = gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: true)
    state.services[0].targetPeerID = "old-local-peer"
    state.services[0].targetInstanceID = nil
    state.services[0].lastKnownTargetHostname = "local"
    let configurationStore = InMemoryGatewayConfigurationStore(state: state)
    let client = RecordingGatewayClient()
    let resolver = MappingMagicDNSResolver(addressesByHostname: [
        "local.et.net": ["10.0.0.10"],
    ])
    let controller = GatewayRuntimeController(
        client: client,
        configurationStore: configurationStore,
        helperRegistration: nil,
        magicDNSResolver: resolver
    )
    let appStore = EasyTierAppStore(client: PreviewEasyTierCoreClient(), storage: .isolatedForTesting())
    var config = NetworkConfig(instance_id: "network-a", network_name: "mesh")
    config.enable_magic_dns = true
    appStore.configs = [config]
    appStore.selectedConfigID = config.instance_id
    let detail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(
            virtual_ipv4: IPv4InetValue(rawValue: "10.0.0.10/24"),
            hostname: "local",
            peer_id: 10
        ),
        running: true,
        applied_magic_dns_enabled: true,
        applied_magic_dns_suffix: "et.net.",
        instance_id: config.instance_id
    )
    appStore.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: detail
        ),
    ]
    appStore.runtimeDetails = [config.network_name: detail]
    controller.bind(to: appStore)
    await controller.load()

    await waitUntil {
        guard let saved = await configurationStore.currentState()?.services.first else {
            return false
        }
        return saved.targetPeerID == "10"
            && saved.targetInstanceID == "network-a"
            && controller.magicDNSState(for: saved.id) == .ready
    }

    let saved = try #require(await configurationStore.currentState()?.services.first)
    #expect(saved.targetPeerID == "10")
    #expect(saved.targetInstanceID == "network-a")
    await waitUntil {
        let applied = await client.lastAppliedConfiguration()
        let started = await client.lastStartedConfiguration()
        return applied != nil || started != nil
    }
    let appliedRuntime = await client.lastAppliedConfiguration()
    let startedRuntime = await client.lastStartedConfiguration()
    let runtime = try #require(appliedRuntime ?? startedRuntime)
    #expect(runtime.routes.first?.upstream.availability == .ready)
    #expect(runtime.routes.first?.upstream.expectedIPv4 == "10.0.0.10")

    let restartedDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(
            virtual_ipv4: IPv4InetValue(rawValue: "10.0.0.10/24"),
            hostname: "local",
            peer_id: 11
        ),
        running: true,
        applied_magic_dns_enabled: true,
        applied_magic_dns_suffix: "et.net.",
        instance_id: config.instance_id
    )
    appStore.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: restartedDetail
        ),
    ]
    appStore.runtimeDetails = [config.network_name: restartedDetail]

    await waitUntil {
        await configurationStore.currentState()?.services.first?.targetPeerID == "11"
    }

    let rebound = try #require(await configurationStore.currentState()?.services.first)
    #expect(rebound.targetPeerID == "11")
    #expect(rebound.targetInstanceID == "network-a")
}

@MainActor
@Test func legacyTargetDoesNotRebindWhenMagicDNSPointsAtWrongIPv4() async throws {
    var state = gatewayControllerTestState(gatewayEnabled: true, serviceEnabled: true)
    state.services[0].targetPeerID = "old-local-peer"
    state.services[0].targetInstanceID = nil
    state.services[0].lastKnownTargetHostname = "local"
    let configurationStore = InMemoryGatewayConfigurationStore(state: state)
    let client = RecordingGatewayClient()
    let resolver = MappingMagicDNSResolver(addressesByHostname: [
        "local.et.net": ["10.0.0.99"],
    ])
    let controller = GatewayRuntimeController(
        client: client,
        configurationStore: configurationStore,
        helperRegistration: nil,
        magicDNSResolver: resolver
    )
    let appStore = EasyTierAppStore(client: PreviewEasyTierCoreClient(), storage: .isolatedForTesting())
    var config = NetworkConfig(instance_id: "network-a", network_name: "mesh")
    config.enable_magic_dns = true
    appStore.configs = [config]
    appStore.selectedConfigID = config.instance_id
    let detail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(
            virtual_ipv4: IPv4InetValue(rawValue: "10.0.0.10/24"),
            hostname: "local",
            peer_id: 10
        ),
        running: true,
        applied_magic_dns_enabled: true,
        applied_magic_dns_suffix: "et.net.",
        instance_id: config.instance_id
    )
    appStore.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: detail
        ),
    ]
    appStore.runtimeDetails = [config.network_name: detail]
    controller.bind(to: appStore)
    await controller.load()

    await waitUntil {
        controller.magicDNSState(for: "service-a")
            == .mismatch(expected: "10.0.0.10", resolved: ["10.0.0.99"])
    }

    let saved = try #require(await configurationStore.currentState()?.services.first)
    #expect(saved.targetPeerID == "old-local-peer")
    #expect(saved.targetInstanceID == nil)
    #expect(
        controller.magicDNSState(for: saved.id)
            == .mismatch(expected: "10.0.0.10", resolved: ["10.0.0.99"])
    )
}

@MainActor
private func waitUntil(
    _ condition: @escaping @MainActor () async -> Bool
) async {
    for _ in 0 ..< 200 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
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
    private var remainingReadyApplyFailures: Int
    private var remainingApplyFailures: Int
    private var applyThenThrowOnce: Bool
    private var readyApplyAttempts = 0
    private var appliedDeployment: GatewayDeploymentIdentity?

    init(
        readyApplyFailures: Int = 0,
        applyFailures: Int = 0,
        applyThenThrowOnce: Bool = false
    ) {
        remainingReadyApplyFailures = readyApplyFailures
        remainingApplyFailures = applyFailures
        self.applyThenThrowOnce = applyThenThrowOnce
    }

    func start(configuration: GatewayConfiguration) {
        calls.append("start")
        startedConfigurations.append(configuration)
        appliedDeployment = configuration.deployment
        isRunning = true
    }

    func apply(configuration: GatewayConfiguration) throws {
        calls.append("apply")
        if remainingApplyFailures > 0 {
            remainingApplyFailures -= 1
            throw CancellationError()
        }
        if configuration.routes.contains(where: { $0.upstream.availability == .ready }) {
            readyApplyAttempts += 1
            if remainingReadyApplyFailures > 0 {
                remainingReadyApplyFailures -= 1
                throw CancellationError()
            }
        }
        appliedConfigurations.append(configuration)
        appliedDeployment = configuration.deployment
        if applyThenThrowOnce {
            applyThenThrowOnce = false
            throw CancellationError()
        }
    }

    func stop() {
        calls.append("stop")
        isRunning = false
        appliedDeployment = nil
    }

    func status() -> GatewayStatus {
        calls.append("status")
        var status = GatewayStatus.stopped
        status.state = isRunning ? .running : .stopped
        status.appliedDeployment = appliedDeployment
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
    func readyApplyAttemptCount() -> Int { readyApplyAttempts }
    func successfulReadyApplyCount() -> Int {
        appliedConfigurations.filter { configuration in
            configuration.routes.contains { $0.upstream.availability == .ready }
        }.count
    }
}

private actor SequencedStatusGatewayClient: GatewayClient {
    private var statuses: [GatewayStatus]
    private var lastStatus: GatewayStatus
    private var appliedDeployment: GatewayDeploymentIdentity?

    init(statuses: [GatewayStatus]) {
        self.statuses = statuses
        lastStatus = statuses.first ?? .stopped
    }

    func start(configuration: GatewayConfiguration) {
        appliedDeployment = configuration.deployment
    }

    func apply(configuration: GatewayConfiguration) {
        appliedDeployment = configuration.deployment
    }

    func stop() {
        lastStatus = .stopped
        appliedDeployment = nil
    }

    func status() -> GatewayStatus {
        if !statuses.isEmpty {
            lastStatus = statuses.removeFirst()
        }
        if lastStatus.state == .running, lastStatus.appliedDeployment == nil {
            lastStatus.appliedDeployment = appliedDeployment
        }
        return lastStatus
    }

    func requestRenewal(certificateID _: String?) {}

    func setRetainsRuntimeAfterDisconnect(_: Bool) {}
}

private actor InMemoryGatewayConfigurationStore: GatewayConfigurationStoring {
    private var state: GatewayPersistedState?
    private var saveCount = 0

    init(state: GatewayPersistedState? = nil) {
        self.state = state
    }

    func load() -> GatewayPersistedState? {
        state
    }

    func save(_ state: GatewayPersistedState) {
        self.state = state
        saveCount += 1
    }

    func currentState() -> GatewayPersistedState? {
        state
    }

    func numberOfSaves() -> Int {
        saveCount
    }
}

private actor InMemoryGatewayCredentialStore: GatewayCredentialStoring {
    private var secrets: [String: GatewayCredentialSecret] = [:]

    func save(_ secret: GatewayCredentialSecret, id: String) {
        secrets[id] = secret
    }

    func load(id: String) -> GatewayCredentialSecret? {
        secrets[id]
    }

    func remove(id: String) {
        secrets.removeValue(forKey: id)
    }

    func resolve(_ descriptors: [GatewayDNSCredentialDescriptor]) throws -> GatewaySecrets {
        var cloudflare: [String: GatewayCloudflareSecret] = [:]
        var aliyun: [String: GatewayAliyunSecret] = [:]
        for descriptor in descriptors {
            guard let secret = secrets[descriptor.id] else {
                throw GatewayCredentialStoreError.missingCredential(
                    id: descriptor.id,
                    label: descriptor.label
                )
            }
            switch (descriptor.provider, secret) {
            case let (.cloudflare, .cloudflare(apiToken)):
                cloudflare[descriptor.id] = GatewayCloudflareSecret(apiToken: apiToken)
            case let (.aliyun, .aliyun(accessKeyID, accessKeySecret)):
                aliyun[descriptor.id] = GatewayAliyunSecret(
                    accessKeyID: accessKeyID,
                    accessKeySecret: accessKeySecret
                )
            default:
                throw GatewayCredentialStoreError.providerMismatch(
                    id: descriptor.id,
                    label: descriptor.label
                )
            }
        }
        return GatewaySecrets(cloudflare: cloudflare, aliyun: aliyun)
    }
}

private actor FixedMagicDNSResolver: MagicDNSResolving {
    let addresses: Set<String>

    init(addresses: Set<String>) {
        self.addresses = addresses
    }

    func resolveIPv4(hostname _: String) -> Set<String> {
        addresses
    }
}

private actor MappingMagicDNSResolver: MagicDNSResolving {
    let addressesByHostname: [String: Set<String>]
    private var resolutionCount = 0

    init(addressesByHostname: [String: Set<String>]) {
        self.addressesByHostname = addressesByHostname
    }

    func resolveIPv4(hostname: String) -> Set<String> {
        resolutionCount += 1
        return addressesByHostname[hostname] ?? []
    }

    func numberOfResolutions() -> Int {
        resolutionCount
    }
}

private actor MutableMagicDNSResolver: MagicDNSResolving {
    private var addressesByHostname: [String: Set<String>] = [:]

    func setAddresses(_ addresses: Set<String>, for hostname: String) {
        addressesByHostname[hostname] = addresses
    }

    func resolveIPv4(hostname: String) -> Set<String> {
        addressesByHostname[hostname] ?? []
    }
}

private func gatewayTestPeerRoute(
    peerID: Int,
    ipv4: String,
    hostname: String,
    instanceID: String? = nil
) -> PeerRoutePair {
    PeerRoutePair(
        route: Route(
            peer_id: peerID,
            ipv4_addr: IPv4InetValue(rawValue: ipv4),
            cost: 1,
            hostname: hostname,
            inst_id: instanceID
        ),
        peer: PeerInfo(peer_id: peerID)
    )
}

private func gatewayTestRouteStatus(
    state: GatewayRouteResolutionState
) -> GatewayRouteStatus {
    GatewayRouteStatus(
        domain: "abc.a.et.net",
        upstream: "http://a.et.net:3000",
        resolvedAddresses: state == .ready ? ["10.0.0.20"] : [],
        certificateID: "service-a",
        resolutionState: state
    )
}

private func gatewayControllerTestState(
    gatewayEnabled: Bool,
    serviceEnabled: Bool
) -> GatewayPersistedState {
    GatewayPersistedState(
        gatewayEnabled: gatewayEnabled,
        acmeAccount: GatewayACMEConfiguration(
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
