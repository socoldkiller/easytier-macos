enum SoftwareUpdateTrack: String, CaseIterable, Identifiable, Sendable {
    case stable
    case nightly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stable: "Latest Stable"
        case .nightly: "Nightly"
        }
    }

    var buildDisplayName: String {
        switch self {
        case .stable: "Stable"
        case .nightly: "Nightly"
        }
    }

    var allowedChannels: Set<String> {
        switch self {
        case .stable: []
        case .nightly: ["nightly"]
        }
    }
}
