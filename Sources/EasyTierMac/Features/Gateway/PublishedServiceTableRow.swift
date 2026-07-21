import EasyTierShared
import Foundation

struct PublishedServiceTableRow: Identifiable, Equatable, Sendable {
    let service: GatewayPublishedService
    let presentation: PublishedServicePresentation
    let proxyIPv4: String
    let sslProvider: PublishedServiceSSLProvider
    let certificatePresentation: PublishedServiceCertificatePresentation
    let lastOnlineAt: Date?

    var id: String { service.id }
    var publicHostname: String { service.publicHostname }
    var targetDomain: String { service.targetDomain }
    var targetPort: Int { service.targetPort }
    var certificateAuthority: GatewayCertificateAuthority { service.certificatePolicy.authority }
    var certificateChallengeLabel: String {
        PublishedServiceChallengeMode(service.certificatePolicy.challenge).label
    }
    var protocolLabel: String { service.upstreamProtocol.rawValue.uppercased() }
    var targetEndpointLabel: String { "\(targetDomain):\(targetPort)" }
    var targetDetailLabel: String { protocolLabel }
    var publicURL: URL? {
        URL(string: "\(sslProvider.urlScheme)://\(publicHostname)")
    }

    func matches(searchTokens: [String]) -> Bool {
        let fields = [
            service.publicHostname,
            service.targetDomain,
            proxyIPv4,
            String(service.targetPort),
            protocolLabel,
            sslProvider.label,
            certificateAuthority.label,
            certificateChallengeLabel,
            certificatePresentation.label,
            "SSL",
            presentation.statusLabel,
            presentation.detailLabel,
            service.desiredEnabled ? "enabled on" : "disabled off",
            lastOnlineAt?.formatted(date: .abbreviated, time: .shortened) ?? "",
            presentation.errorMessage ?? "",
        ]
        return searchTokens.allSatisfy { token in
            fields.contains { $0.localizedStandardContains(token) }
        }
    }
}
