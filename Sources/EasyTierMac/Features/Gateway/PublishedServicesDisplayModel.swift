import EasyTierShared
import Foundation

struct PublishedServicesDisplayModel: Equatable, Sendable {
    let runtimePresentation: GatewayRuntimePresentation
    let networkName: String
    let rows: [PublishedServiceTableRow]
    let filteredRows: [PublishedServiceTableRow]
    let certificateFailures: [PublishedServiceCertificateFailure]
    let searchIsActive: Bool
    let liveCount: Int

    init(
        services: [GatewayPublishedService],
        status: GatewayStatus,
        gatewayEnabled: Bool,
        acmeConfiguration: GatewayACMEConfiguration?,
        networkName: String,
        members: [NetworkMemberStatus],
        searchText: String,
        magicDNSState: MagicDNSOperationalState = .ready,
        magicDNSStateByServiceID: [String: MagicDNSOperationalState] = [:],
        convergence: GatewayConvergenceSnapshot? = nil
    ) {
        runtimePresentation = GatewayRuntimePresentation(
            status: status,
            desiredEnabled: gatewayEnabled,
            services: services,
            magicDNSState: magicDNSState,
            convergence: convergence ?? .disabled
        )
        self.networkName = networkName
        let contactEmail = try? GatewayPublishedServicesValidator.normalizeContactEmail(
            acmeConfiguration?.contactEmail
        )
        let tlsConfigured = acmeConfiguration?.termsOfServiceAgreed == true
            && contactEmail != nil
        let configurationApplied = convergence?.isConverged ?? true

        var certificatesByID: [String: GatewayCertificateStatus] = [:]
        for certificate in status.certificates {
            certificatesByID[certificate.id] = certificate
        }
        var routesByDomain: [String: GatewayRouteStatus] = [:]
        for route in status.routes {
            routesByDomain[route.domain] = route
        }

        rows = services.map { service in
            let certificate = certificatesByID[service.id]
            let route = routesByDomain[service.publicHostname]
            let presentation = PublishedServicePresentation(
                service: service,
                certificate: certificate,
                route: route,
                gatewayEnabled: gatewayEnabled,
                tlsConfigured: tlsConfigured,
                gatewayState: status.state,
                magicDNSState: magicDNSStateByServiceID[service.id] ?? magicDNSState,
                configurationApplied: configurationApplied,
                convergenceMessage: convergence?.message
            )
            let resolvedIPv4 = PublishedServiceTargetResolver.ipv4(
                for: service,
                route: route,
                members: members
            )
            let sslProvider = PublishedServiceSSLProvider(
                acmeConfiguration: acmeConfiguration,
                certificate: certificate
            )
            return PublishedServiceTableRow(
                service: service,
                presentation: presentation,
                proxyIPv4: resolvedIPv4 ?? "—",
                sslProvider: sslProvider,
                certificatePresentation: PublishedServiceCertificatePresentation(
                    provider: sslProvider,
                    certificate: certificate
                ),
                runtimeCertificateAuthority: certificate?.authority,
                runtimeCertificateChallenge: certificate?.challenge,
                configurationApplied: configurationApplied,
                lastOnlineAt: Self.date(from: route?.lastOnlineAt)
            )
        }

        certificateFailures = rows.compactMap { row in
            guard row.service.desiredEnabled,
                  configurationApplied,
                  let message = row.certificatePresentation.errorMessage?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty
            else {
                return nil
            }
            switch row.certificatePresentation.state {
            case .degraded, .failed:
                return PublishedServiceCertificateFailure(
                    id: row.id,
                    hostname: row.publicHostname,
                    message: message
                )
            case .unavailable, .notIssued, .issuing, .renewing, .active, .expires,
                 .expiresSoon, .expired:
                return nil
            }
        }

        let tokens = searchText
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        searchIsActive = !tokens.isEmpty
        filteredRows = tokens.isEmpty ? rows : rows.filter { $0.matches(searchTokens: tokens) }
        liveCount = rows.filter(\.presentation.canOpen).count
    }

    var contentMotionID: String {
        if rows.isEmpty { return "services-empty" }
        if searchIsActive, filteredRows.isEmpty { return "services-search-empty" }
        return searchIsActive ? "services-search" : "services-all"
    }

    var serviceSummary: String {
        Self.serviceSummary(liveCount: liveCount, serviceCount: rows.count)
    }

    static func serviceSummary(liveCount: Int, serviceCount: Int) -> String {
        "\(liveCount) of \(serviceCount) live"
    }

    private static func date(from timestamp: String?) -> Date? {
        guard let timestamp else { return nil }
        return try? Date(timestamp, strategy: .iso8601)
    }
}
