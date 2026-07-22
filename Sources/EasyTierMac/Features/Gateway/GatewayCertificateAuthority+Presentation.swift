import EasyTierShared
import Foundation

extension GatewayCertificateAuthority {
    var label: String {
        switch self {
        case .letsEncrypt: "Let's Encrypt"
        case .zeroSSL: "ZeroSSL"
        }
    }

    var termsURL: URL {
        let value = switch self {
        case .letsEncrypt: "https://letsencrypt.org/repository/"
        case .zeroSSL: "https://zerossl.com/terms/"
        }
        return URL(string: value) ?? URL(fileURLWithPath: "/")
    }
}
