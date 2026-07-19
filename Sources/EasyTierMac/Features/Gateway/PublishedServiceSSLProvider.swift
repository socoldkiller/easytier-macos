import EasyTierShared

enum PublishedServiceSSLProvider: Equatable, Sendable {
    case httpOnly
    case letsEncrypt

    init(acmeConfiguration: GatewayACMEConfiguration?) {
        guard let acmeConfiguration, acmeConfiguration.termsOfServiceAgreed else {
            self = .httpOnly
            return
        }

        switch acmeConfiguration.directory {
        case .letsencryptStaging, .letsencryptProduction:
            self = .letsEncrypt
        }
    }

    var label: String {
        switch self {
        case .httpOnly: "HTTP Only"
        case .letsEncrypt: "Let's Encrypt"
        }
    }

    var urlScheme: String {
        switch self {
        case .httpOnly: "http"
        case .letsEncrypt: "https"
        }
    }

    var connectionLabel: String {
        switch self {
        case .httpOnly: "Unencrypted HTTP"
        case .letsEncrypt: "Managed HTTPS"
        }
    }

    var helpText: String {
        switch self {
        case .httpOnly: "This service is published over HTTP without an SSL certificate."
        case .letsEncrypt: "SSL certificates are managed by Let's Encrypt."
        }
    }

    var isSecure: Bool {
        self != .httpOnly
    }
}
