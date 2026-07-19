import Foundation
import Testing
@testable import EasyTierMac
@testable import EasyTierShared

@Test func publishedServiceSSLProviderReflectsConfiguredACMEProvider() {
    let notAccepted = GatewayACMEConfiguration(
        directory: .letsencryptProduction,
        termsOfServiceAgreed: false
    )
    let production = GatewayACMEConfiguration(
        directory: .letsencryptProduction,
        termsOfServiceAgreed: true
    )
    let staging = GatewayACMEConfiguration(
        directory: .letsencryptStaging,
        termsOfServiceAgreed: true
    )

    #expect(PublishedServiceSSLProvider(acmeConfiguration: nil) == .httpOnly)
    #expect(PublishedServiceSSLProvider(acmeConfiguration: notAccepted) == .httpOnly)
    #expect(PublishedServiceSSLProvider(acmeConfiguration: production) == .letsEncrypt)
    #expect(PublishedServiceSSLProvider(acmeConfiguration: staging) == .letsEncrypt)
    #expect(PublishedServiceSSLProvider.httpOnly.label == "HTTP Only")
    #expect(PublishedServiceSSLProvider.letsEncrypt.label == "Let's Encrypt")
    #expect(PublishedServiceSSLProvider.httpOnly.urlScheme == "http")
    #expect(PublishedServiceSSLProvider.letsEncrypt.urlScheme == "https")
}

@Test func publishedServiceTargetIPv4UsesTopologyInsteadOfGatewayDNS() {
    let service = servicesTestService(id: "service-a", hostname: "service-a.a.et.net", port: 3_000)
    let member = servicesTestMember(peerID: service.targetPeerID, ipv4: "10.0.0.5/24")
    let route = servicesTestRoute(
        service: service,
        state: .ready,
        resolvedAddresses: ["not-an-address", "10.0.0.42"]
    )

    #expect(
        PublishedServiceTargetResolver.ipv4(for: service, route: route, members: [member])
            == "10.0.0.5"
    )
    #expect(
        PublishedServiceTargetResolver.ipv4(for: service, route: nil, members: [member])
            == "10.0.0.5"
    )
    #expect(PublishedServiceTargetResolver.ipv4(for: service, route: nil, members: []) == nil)
}

@Test func publishedServiceTargetIPv4FollowsStableInstanceAcrossPeerIDChanges() {
    var service = servicesTestService(
        id: "service-a",
        hostname: "service-a.a.et.net",
        port: 3_000
    )
    service.targetPeerID = "old-peer"
    service.targetInstanceID = "target-instance"
    let member = servicesTestMember(
        peerID: "new-peer",
        instanceID: "target-instance",
        ipv4: "10.0.0.5/24"
    )

    #expect(
        PublishedServiceTargetResolver.ipv4(for: service, route: nil, members: [member])
            == "10.0.0.5"
    )
}

@Test func publishedServiceTargetOptionsKeepCurrentTargetAndExposeMemberIPv4() {
    let service = servicesTestService(id: "service-a", hostname: "service-a.a.et.net", port: 3_000)
    let member = servicesTestMember(peerID: "peer-b", ipv4: "10.0.0.8/24", hostname: "beta")

    let options = PublishedServiceTargetOption.options(
        for: service,
        currentIPv4: "10.0.0.5",
        members: [member]
    )

    #expect(options.map(\.peerID) == ["peer-a", "peer-b"])
    #expect(options.first?.ipv4 == "10.0.0.5")
    #expect(options.last?.label == "10.0.0.8 - beta")
}

@Test func publishedServicePresentationDoesNotReportStaleLiveStateWhileStarting() {
    let service = servicesTestService(id: "service-a", hostname: "service-a.a.et.net", port: 3_000)
    let presentation = PublishedServicePresentation(
        service: service,
        certificate: servicesTestCertificate(
            id: service.id,
            domain: service.publicHostname,
            state: .active
        ),
        route: servicesTestRoute(
            service: service,
            state: .ready,
            resolvedAddresses: ["10.0.0.1"]
        ),
        gatewayEnabled: true,
        tlsConfigured: true,
        gatewayState: .starting
    )

    #expect(presentation.statusLabel == "Starting")
    #expect(!presentation.canOpen)
    #expect(!presentation.canRetryCertificate)
}

@Test func publishedServicesDisplayBuildsRowsSearchesAndCountsLiveServices() {
    let serviceA = servicesTestService(
        id: "service-a",
        hostname: "service-a.alpha.et.net",
        targetHostname: "alpha",
        port: 3_000
    )
    let serviceB = servicesTestService(
        id: "service-b",
        hostname: "service-b.beta.et.net",
        targetHostname: "beta",
        port: 8_080
    )
    let status = servicesTestStatus(
        state: .running,
        routes: [
            servicesTestRoute(
                service: serviceA,
                state: .ready,
                resolvedAddresses: ["10.0.0.10"],
                lastOnlineAt: "2026-07-19T10:20:30.123456789Z"
            ),
            servicesTestRoute(service: serviceB, state: .ready, resolvedAddresses: ["10.0.0.2"]),
        ],
        certificates: [
            servicesTestCertificate(id: serviceA.id, domain: serviceA.publicHostname, state: .active),
            servicesTestCertificate(id: serviceB.id, domain: serviceB.publicHostname, state: .active),
        ]
    )

    let display = PublishedServicesDisplayModel(
        services: [serviceB, serviceA],
        status: status,
        gatewayEnabled: true,
        acmeConfiguration: GatewayACMEConfiguration(
            directory: .letsencryptProduction,
            termsOfServiceAgreed: true
        ),
        networkName: "Production",
        members: [servicesTestMember(peerID: serviceA.targetPeerID, ipv4: "10.0.0.10/24")],
        searchText: "SERVICE-A 10.0.0.10 ENCRYPT LIVE"
    )

    #expect(display.networkName == "Production")
    #expect(display.rows.count == 2)
    #expect(display.liveCount == 2)
    #expect(display.filteredRows.map(\.id) == [serviceA.id])
    #expect(display.filteredRows.first?.targetDomain == "alpha.et.net")
    #expect(display.filteredRows.first?.protocolLabel == "HTTP")
    #expect(display.filteredRows.first?.sslProvider == .letsEncrypt)
    #expect(
        display.filteredRows.first?.lastOnlineAt
            == (try? Date("2026-07-19T10:20:30.123456789Z", strategy: .iso8601))
    )
}

@Test func servicesWorkspaceUsesTheExpectedToolbarDestination() {
    #expect(
        WorkspaceTab.displayOrder.map(\.id)
            == ["Status", "Services", "View", "Config", "Peers", "Logs"]
    )
    #expect(WorkspaceTab.services.systemImage == "network.badge.shield.half.filled")
    #expect(
        PublishedServiceGridColumn.allCases.map(\.title)
            == ["Domain", "Proxy IPv4", "Port", "Protocol", "SSL", "Status", "Last Online", ""]
    )
}

private func servicesTestService(
    id: String,
    hostname: String,
    targetHostname: String = "target",
    port: Int
) -> GatewayPublishedService {
    GatewayPublishedService(
        id: id,
        networkConfigID: "network-a",
        targetPeerID: "peer-a",
        publicNodeLabel: targetHostname,
        publicDNSSuffix: "et.net.",
        lastKnownTargetHostname: targetHostname,
        lastKnownMagicDNSSuffix: "et.net.",
        serviceLabel: id,
        publicHostname: hostname,
        targetPort: port,
        desiredEnabled: true
    )
}

private func servicesTestCertificate(
    id: String,
    domain: String,
    state: GatewayCertificateState
) -> GatewayCertificateStatus {
    GatewayCertificateStatus(
        id: id,
        domains: [domain],
        challenge: "http-01",
        state: state,
        notBefore: nil,
        notAfter: nil,
        nextRenewalAt: nil,
        lastAttemptAt: nil,
        lastError: nil
    )
}

private func servicesTestRoute(
    service: GatewayPublishedService,
    state: GatewayRouteResolutionState,
    resolvedAddresses: [String],
    lastOnlineAt: String? = nil
) -> GatewayRouteStatus {
    GatewayRouteStatus(
        domain: service.publicHostname,
        upstream: "http://\(service.targetDomain):\(service.targetPort)",
        resolvedAddresses: resolvedAddresses,
        certificateID: service.id,
        resolutionState: state,
        lastResolvedAt: nil,
        lastOnlineAt: lastOnlineAt,
        lastError: nil
    )
}

private func servicesTestStatus(
    state: GatewayState,
    routes: [GatewayRouteStatus] = [],
    certificates: [GatewayCertificateStatus] = []
) -> GatewayStatus {
    GatewayStatus(
        schemaVersion: GatewaySchema.version,
        state: state,
        configGeneration: 1,
        listeners: GatewayListenerStatus(http: "127.0.0.1:80", https: "127.0.0.1:443"),
        routes: routes,
        certificates: certificates,
        pendingDNSCleanups: 0,
        lastError: nil
    )
}

private func servicesTestMember(
    peerID: String,
    instanceID: String = "network-a",
    ipv4: String,
    hostname: String = "target"
) -> NetworkMemberStatus {
    NetworkMemberStatus(
        id: "peer-\(peerID)",
        isLocal: false,
        peerID: peerID,
        instanceID: instanceID,
        virtualIPv4: ipv4,
        hostname: hostname,
        version: "2.4.0",
        routeCost: "P2P",
        tunnelProto: "tcp",
        latency: "10 ms",
        uploadTotal: "1 KiB",
        downloadTotal: "2 KiB",
        lossRate: "0%",
        natType: "FullCone",
        isPublicServer: false,
        txBytes: 1_024,
        rxBytes: 2_048,
        availability: .online
    )
}
