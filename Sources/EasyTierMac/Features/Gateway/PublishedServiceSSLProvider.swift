import EasyTierShared

enum PublishedServiceSSLProvider: Equatable, Sendable {
    case unavailable
    case managedHTTPS
    case requesting

    init(
        acmeConfiguration: GatewayACMEConfiguration?,
        certificate: GatewayCertificateStatus? = nil
    ) {
        let contactEmail = try? GatewayPublishedServicesValidator.normalizeContactEmail(
            acmeConfiguration?.contactEmail
        )
        guard acmeConfiguration?.termsOfServiceAgreed == true, contactEmail != nil else {
            self = .unavailable
            return
        }
        switch certificate?.availability {
        case .valid:
            self = .managedHTTPS
        case .expired, .unavailable, nil:
            self = .requesting
        }
    }

    var label: String {
        switch self {
        case .unavailable: "Email Required"
        case .managedHTTPS: "Secure"
        case .requesting: "Issuing Certificate"
        }
    }

    var urlScheme: String {
        switch self {
        case .unavailable, .managedHTTPS, .requesting: "https"
        }
    }

    var connectionLabel: String {
        switch self {
        case .unavailable: "Automatic HTTPS Needs Setup"
        case .managedHTTPS: "Secure with Automatic HTTPS"
        case .requesting: "Certificate Issuance in Progress"
        }
    }

    var helpText: String {
        switch self {
        case .unavailable: "Add a certificate contact email to enable Automatic HTTPS."
        case .managedHTTPS: "Automatic HTTPS is active with a certificate from the selected authority."
        case .requesting: "Automatic HTTPS is issuing a certificate."
        }
    }

    var isSecure: Bool {
        self == .managedHTTPS
    }
}
