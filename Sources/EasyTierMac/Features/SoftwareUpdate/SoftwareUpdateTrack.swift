enum SoftwareUpdateTrack: String, CaseIterable, Identifiable, Sendable {
    case stable
    case nightly
    case dev

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stable: "Latest Stable"
        case .nightly: "Nightly"
        case .dev: "Dev"
        }
    }

    var buildDisplayName: String {
        switch self {
        case .stable: "Stable"
        case .nightly: "Nightly"
        case .dev: "Dev"
        }
    }

    var allowedChannels: Set<String> {
        switch self {
        case .stable: []
        case .nightly: ["nightly"]
        case .dev: ["dev"]
        }
    }
}
