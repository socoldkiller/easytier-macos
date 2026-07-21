import EasyTierShared

extension GatewayCertificateAuthority {
    var label: String {
        switch self {
        case .letsEncrypt: "Let's Encrypt"
        case .zeroSSL: "ZeroSSL"
        }
    }
}
