package enum PrivilegedHelperKind: Sendable {
    case easyTier
    case gateway

    package var displayName: String {
        switch self {
        case .easyTier: "EasyTier helper"
        case .gateway: "Gateway helper"
        }
    }
}
