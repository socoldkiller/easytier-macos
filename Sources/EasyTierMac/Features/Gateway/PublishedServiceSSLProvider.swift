import EasyTierShared

enum PublishedServiceSSLProvider: Equatable, Sendable {
    case httpOnly
    case managedHTTPS
    case requesting

    init(
        acmeConfiguration: GatewayACMEConfiguration?,
        certificate: GatewayCertificateStatus? = nil
    ) {
        guard let acmeConfiguration, acmeConfiguration.termsOfServiceAgreed else {
            self = .httpOnly
            return
        }
        switch certificate?.servingMode {
        case .httpOnly:
            self = .httpOnly
        case .https:
            self = .managedHTTPS
        case .pendingHTTPS, nil:
            self = .requesting
        }
    }

    var label: String {
        switch self {
        case .httpOnly: "HTTP Only"
        case .managedHTTPS: "Managed HTTPS"
        case .requesting: "Requesting Certificate"
        }
    }

    var urlScheme: String {
        switch self {
        case .httpOnly: "http"
        case .managedHTTPS, .requesting: "https"
        }
    }

    var connectionLabel: String {
        switch self {
        case .httpOnly: "Unencrypted HTTP"
        case .managedHTTPS: "Certificate Managed"
        case .requesting: "HTTPS Pending"
        }
    }

    var helpText: String {
        switch self {
        case .httpOnly: "Certificate services are unavailable. HTTP remains available while HTTPS is retried."
        case .managedHTTPS: "The service uses an automatically managed certificate."
        case .requesting: "A managed certificate is being requested."
        }
    }

    var isSecure: Bool {
        self == .managedHTTPS
    }
}
