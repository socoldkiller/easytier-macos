import EasyTierShared

enum PublishedServiceSSLProvider: Equatable, Sendable {
    case unavailable
    case managedHTTPS
    case requesting

    init(
        acmeConfiguration: GatewayACMEConfiguration?,
        certificate: GatewayCertificateStatus? = nil
    ) {
        guard let acmeConfiguration, acmeConfiguration.termsOfServiceAgreed else {
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
        case .unavailable: "HTTPS Setup Required"
        case .managedHTTPS: "Managed HTTPS"
        case .requesting: "Requesting Certificate"
        }
    }

    var urlScheme: String {
        switch self {
        case .unavailable, .managedHTTPS, .requesting: "https"
        }
    }

    var connectionLabel: String {
        switch self {
        case .unavailable: "Managed HTTPS Unavailable"
        case .managedHTTPS: "Certificate Managed"
        case .requesting: "HTTPS Pending"
        }
    }

    var helpText: String {
        switch self {
        case .unavailable: "Configure managed certificates before enabling this service."
        case .managedHTTPS: "The service uses a managed certificate from its selected authority."
        case .requesting: "A managed certificate is being requested."
        }
    }

    var isSecure: Bool {
        self == .managedHTTPS
    }
}
