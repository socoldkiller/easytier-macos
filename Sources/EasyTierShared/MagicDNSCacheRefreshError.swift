import Foundation

public enum MagicDNSCacheRefreshError: LocalizedError, Equatable, Sendable {
    case launchFailed(executable: String, message: String)
    case commandFailed(executable: String, status: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(executable, message):
            "Could not launch DNS cache refresh command \(executable): \(message)"
        case let .commandFailed(executable, status, output):
            if output.isEmpty {
                "DNS cache refresh command \(executable) failed with status \(status)."
            } else {
                "DNS cache refresh command \(executable) failed with status \(status): \(output)"
            }
        }
    }
}
