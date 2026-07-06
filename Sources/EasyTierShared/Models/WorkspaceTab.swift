public enum WorkspaceTab: String, CaseIterable, Identifiable, Sendable {
    case status = "Status"
    case view = "View"
    case config = "Config"
    case logs = "Logs"
    case peers = "Peers"

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .status: "Status"
        case .view: "Traffic"
        case .config: "Config"
        case .logs: "Logs"
        case .peers: "Peers"
        }
    }
}
