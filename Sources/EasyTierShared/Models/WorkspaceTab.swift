public enum WorkspaceTab: String, CaseIterable, Identifiable, Sendable {
    case status = "Status"
    case view = "View"
    case config = "Config"
    case logs = "Logs"

    public var id: String { rawValue }
}
