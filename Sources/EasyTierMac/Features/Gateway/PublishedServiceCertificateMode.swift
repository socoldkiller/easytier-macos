import EasyTierShared

enum PublishedServiceCertificateMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case custom

    var id: Self { self }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .custom: "Custom"
        }
    }
}

