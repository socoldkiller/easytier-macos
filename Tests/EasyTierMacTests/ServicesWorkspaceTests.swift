import Foundation
import Testing
@testable import EasyTierMac
@testable import EasyTierShared

@Test func publishedServiceSSLProviderUsesCertificateServingMode() {
    let notAccepted = GatewayACMEConfiguration(
        contactEmail: "ops@example.com",
        acceptedAuthorities: []
    )
    let missingContactEmail = GatewayACMEConfiguration(
        acceptedAuthorities: GatewayCertificateAuthority.allCases
    )
    let production = GatewayACMEConfiguration(
        contactEmail: "ops@example.com",
        acceptedAuthorities: GatewayCertificateAuthority.allCases
    )
    let staging = GatewayACMEConfiguration(
        contactEmail: "ops@example.com",
        acceptedAuthorities: GatewayCertificateAuthority.allCases
    )

    #expect(PublishedServiceSSLProvider(acmeConfiguration: nil) == .unavailable)
    #expect(PublishedServiceSSLProvider(acmeConfiguration: notAccepted) == .unavailable)
    #expect(PublishedServiceSSLProvider(acmeConfiguration: missingContactEmail) == .unavailable)
    #expect(PublishedServiceSSLProvider(acmeConfiguration: production) == .requesting)
    #expect(PublishedServiceSSLProvider(acmeConfiguration: staging) == .requesting)
    #expect(PublishedServiceSSLProvider.unavailable.label == "Email Required")
    #expect(PublishedServiceSSLProvider.managedHTTPS.label == "Secure")
    #expect(PublishedServiceSSLProvider.requesting.label == "Issuing Certificate")
    #expect(PublishedServiceSSLProvider.unavailable.urlScheme == "https")
    #expect(PublishedServiceSSLProvider.managedHTTPS.urlScheme == "https")
}

@Test func publishedServiceCertificatePresentationDistinguishesExpiryStates() throws {
    let now = try Date("2026-07-20T00:00:00Z", strategy: .iso8601)
    let futureExpiration = try Date("2026-09-21T00:00:00Z", strategy: .iso8601)
    let soonExpiration = try Date("2026-08-01T00:00:00Z", strategy: .iso8601)
    let expiredAt = try Date("2026-07-01T00:00:00Z", strategy: .iso8601)

    let future = PublishedServiceCertificatePresentation(
        provider: .managedHTTPS,
        certificate: servicesTestCertificate(
            id: "future",
            domain: "future.et.net",
            state: .active,
            notAfter: "2026-09-21T00:00:00Z"
        ),
        now: now
    )
    let soon = PublishedServiceCertificatePresentation(
        provider: .managedHTTPS,
        certificate: servicesTestCertificate(
            id: "soon",
            domain: "soon.et.net",
            state: .active,
            notAfter: "2026-08-01T00:00:00Z"
        ),
        now: now
    )
    let expired = PublishedServiceCertificatePresentation(
        provider: .managedHTTPS,
        certificate: servicesTestCertificate(
            id: "expired",
            domain: "expired.et.net",
            state: .active,
            notAfter: "2026-07-01T00:00:00Z"
        ),
        now: now
    )

    #expect(future.state == .expires(futureExpiration))
    #expect(future.tone == .positive)
    #expect(soon.state == .expiresSoon(soonExpiration))
    #expect(soon.tone == .warning)
    #expect(expired.state == .expired(expiredAt))
    #expect(expired.tone == .warning)
}

@Test func publishedServiceCertificatePresentationHandlesOperationalStates() {
    let unavailable = PublishedServiceCertificatePresentation(
        provider: .unavailable,
        certificate: nil
    )
    let notIssued = PublishedServiceCertificatePresentation(
        provider: .requesting,
        certificate: nil
    )
    let renewing = PublishedServiceCertificatePresentation(
        provider: .managedHTTPS,
        certificate: servicesTestCertificate(
            id: "renewing",
            domain: "renewing.et.net",
            state: .renewing
        )
    )
    let failed = PublishedServiceCertificatePresentation(
        provider: .managedHTTPS,
        certificate: servicesTestCertificate(
            id: "failed",
            domain: "failed.et.net",
            state: .failed,
            lastError: "ACME request failed"
        )
    )
    let degraded = PublishedServiceCertificatePresentation(
        provider: .managedHTTPS,
        certificate: servicesTestCertificate(
            id: "degraded",
            domain: "degraded.et.net",
            state: .degraded
        )
    )

    #expect(unavailable.state == .unavailable)
    #expect(unavailable.label == "—")
    #expect(notIssued.state == .notIssued)
    #expect(renewing.state == .renewing)
    #expect(renewing.label == "Renewing…")
    #expect(degraded.state == .degraded)
    #expect(degraded.label == "Delayed")
    #expect(failed.state == .failed)
    #expect(failed.helpText == "ACME request failed")
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
    #expect(options.last?.label == "beta — 10.0.0.8")
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
            contactEmail: "ops@example.com",
            acceptedAuthorities: GatewayCertificateAuthority.allCases
        ),
        networkName: "Production",
        members: [servicesTestMember(peerID: serviceA.targetPeerID, ipv4: "10.0.0.10/24")],
        searchText: "SERVICE-A 10.0.0.10 HTTPS LIVE"
    )

    #expect(display.networkName == "Production")
    #expect(display.rows.count == 2)
    #expect(display.liveCount == 2)
    #expect(display.serviceSummary == "2 of 2 live")
    #expect(display.filteredRows.map(\.id) == [serviceA.id])
    #expect(display.filteredRows.first?.targetDomain == "alpha.et.net")
    #expect(display.filteredRows.first?.protocolLabel == "HTTP")
    #expect(display.filteredRows.first?.targetEndpointLabel == "alpha.et.net:3000")
    #expect(display.filteredRows.first?.targetDetailLabel == "HTTP")
    #expect(display.filteredRows.first?.sslProvider == .managedHTTPS)
    #expect(
        display.filteredRows.first?.lastOnlineAt
            == (try? Date("2026-07-19T10:20:30.123456789Z", strategy: .iso8601))
    )
}

@Test func publishedServicesDisplayExposesCertificateFailuresForBanner() {
    let failedService = servicesTestService(
        id: "failed-service",
        hostname: "failed.example.com",
        port: 8_080
    )
    let activeService = servicesTestService(
        id: "active-service",
        hostname: "active.example.com",
        port: 3_000
    )
    let display = PublishedServicesDisplayModel(
        services: [failedService, activeService],
        status: servicesTestStatus(
            state: .running,
            certificates: [
                servicesTestCertificate(
                    id: failedService.id,
                    domain: failedService.publicHostname,
                    state: .failed,
                    lastError: "ACME authorization timed out"
                ),
                servicesTestCertificate(
                    id: activeService.id,
                    domain: activeService.publicHostname,
                    state: .active,
                    lastError: "stale error"
                ),
            ]
        ),
        gatewayEnabled: true,
        acmeConfiguration: GatewayACMEConfiguration(
            contactEmail: "ops@example.com",
            acceptedAuthorities: GatewayCertificateAuthority.allCases
        ),
        networkName: "Production",
        members: [],
        searchText: ""
    )

    #expect(
        display.certificateFailures == [
            PublishedServiceCertificateFailure(
                id: failedService.id,
                hostname: failedService.publicHostname,
                message: "ACME authorization timed out"
            ),
        ]
    )
}

@Test(
    "Service summaries combine live and total counts",
    arguments: [
        (0, 0, "0 of 0 live"),
        (1, 3, "1 of 3 live"),
        (3, 3, "3 of 3 live"),
    ]
)
func publishedServiceSummary(liveCount: Int, serviceCount: Int, expected: String) {
    #expect(
        PublishedServicesDisplayModel.serviceSummary(
            liveCount: liveCount,
            serviceCount: serviceCount
        ) == expected
    )
}

@Test func publishedServiceCreationTargetsPreferLocalAndFilterUnavailableMembers() {
    let members = [
        servicesTestMember(
            peerID: "peer-zeta",
            ipv4: "10.0.0.9/24",
            hostname: "zeta"
        ),
        servicesTestMember(
            peerID: "peer-offline",
            ipv4: "10.0.0.8/24",
            hostname: "offline",
            availability: .connecting
        ),
        servicesTestMember(
            peerID: "-",
            ipv4: "10.0.0.7/24",
            hostname: "invalid"
        ),
        servicesTestMember(
            peerID: "peer-local",
            ipv4: "",
            hostname: "local",
            isLocal: true
        ),
        servicesTestMember(
            peerID: "peer-alpha",
            ipv4: "10.0.0.2/24",
            hostname: "alpha"
        ),
        servicesTestMember(
            peerID: "peer-alpha",
            ipv4: "10.0.0.3/24",
            hostname: "duplicate"
        ),
    ]

    let options = PublishedServiceTargetOption.creationOptions(members: members)

    #expect(options.map(\.peerID) == ["peer-local", "peer-alpha", "peer-zeta"])
    #expect(options.first?.label == "local — Address unavailable")
    #expect(options[1].label == "alpha — 10.0.0.2")
}

@Test func publishedServiceCreationTargetSelectionUsesPreferredThenLocal() {
    let options = PublishedServiceTargetOption.creationOptions(members: [
        servicesTestMember(
            peerID: "peer-remote",
            ipv4: "10.0.0.2/24",
            hostname: "remote"
        ),
        servicesTestMember(
            peerID: "peer-local",
            ipv4: "10.0.0.1/24",
            hostname: "local",
            isLocal: true
        ),
    ])

    #expect(
        PublishedServiceTargetOption.initialPeerID(
            in: options,
            preferredPeerID: "peer-remote"
        ) == "peer-remote"
    )
    #expect(
        PublishedServiceTargetOption.initialPeerID(
            in: options,
            preferredPeerID: "missing"
        ) == "peer-local"
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
            == ["Service", "IPv4", "Target", "HTTPS", "Expires", "Last Online", "Enabled", ""]
    )
    #expect(PublishedServiceGridColumn.service.minimumWidth == 324)
    #expect(PublishedServiceGridColumn.service.idealWidth == 398)
    #expect(PublishedServiceGridColumn.ipv4.minimumWidth == 142)
    #expect(PublishedServiceGridColumn.ipv4.idealWidth == 156)
    #expect(PublishedServiceGridColumn.target.idealWidth >= 200)
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
        desiredEnabled: true,
        certificateID: id
    )
}

private func servicesTestCertificate(
    id: String,
    domain: String,
    state: ServicesTestCertificateState,
    notAfter: String? = nil,
    nextRenewalAt: String? = nil,
    lastError: String? = nil
) -> GatewayCertificateStatus {
    let availability: GatewayCertificateAvailability = switch state {
    case .active, .renewing, .degraded: .valid
    case .failed: .unavailable
    }
    let operation: GatewayCertificateOperation = switch state {
    case .active: .idle
    case .renewing: .renewing
    case .degraded: .waitingRetry
    case .failed: .suspended
    }
    let failure = lastError.map {
        GatewayFailure(
            source: .acmeAuthorization,
            kind: state == .failed ? .userActionRequired : .transient,
            code: state == .failed ? "unauthorized" : "retry_scheduled",
            message: $0,
            occurredAt: "2026-07-20T00:00:00Z",
            retryAt: state == .degraded ? "2026-07-20T00:05:00Z" : nil,
            authority: .letsEncrypt,
            challenge: "HTTP-01",
            dnsProvider: nil,
            acmeProblemType: nil,
            httpStatus: nil
        )
    }
    return GatewayCertificateStatus(
        id: id,
        domains: [domain],
        authority: .letsEncrypt,
        challenge: "http-01",
        activeAuthority: availability == .valid ? .letsEncrypt : nil,
        activeChallenge: availability == .valid ? "http-01" : nil,
        availability: availability,
        operation: operation,
        stage: nil,
        notBefore: nil,
        notAfter: notAfter,
        nextRenewalAt: nextRenewalAt,
        nextAttemptAt: state == .degraded ? "2026-07-20T00:05:00Z" : nil,
        lastAttemptAt: nil,
        failure: failure
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
        appliedDeployment: .manual,
        listeners: GatewayListenerStatus(http: "127.0.0.1:80", https: "127.0.0.1:443"),
        routes: routes,
        certificates: certificates,
        pendingDNSCleanups: 0,
        providerCooldowns: [],
        runtimeIssues: []
    )
}

private enum ServicesTestCertificateState: Equatable {
    case active
    case renewing
    case degraded
    case failed
}

private func servicesTestMember(
    peerID: String,
    instanceID: String = "network-a",
    ipv4: String,
    hostname: String = "target",
    isLocal: Bool = false,
    availability: RuntimeMemberAvailability = .online
) -> NetworkMemberStatus {
    NetworkMemberStatus(
        id: "peer-\(peerID)",
        isLocal: isLocal,
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
        availability: availability
    )
}
