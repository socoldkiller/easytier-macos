import EasyTierShared

enum PublishedServiceChallengeMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case http01
    case dns01

    var id: Self { self }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .http01: "HTTP-01"
        case .dns01: "DNS-01"
        }
    }

    init(_ challenge: GatewayPublishedServiceChallenge) {
        switch challenge {
        case .automatic: self = .automatic
        case .http01: self = .http01
        case .dns01: self = .dns01
        }
    }

    func challenge(credentialID: String?) -> GatewayPublishedServiceChallenge? {
        switch self {
        case .automatic:
            return .automatic(dnsCredentialID: credentialID)
        case .http01:
            return .http01
        case .dns01:
            guard let credentialID else { return nil }
            return .dns01(credentialID: credentialID)
        }
    }
}

extension GatewayPublishedServiceChallenge {
    var dnsCredentialID: String? {
        switch self {
        case let .automatic(dnsCredentialID): dnsCredentialID
        case .http01: nil
        case let .dns01(credentialID): credentialID
        }
    }
}
