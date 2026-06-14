import Foundation

public enum EasyTierPrivilegedHelperConstants {
    public static let bundleIdentifier = "com.kkrainbow.easytier.mac.helper"
    public static let machServiceName = "com.kkrainbow.easytier.mac.helper"
    public static let launchDaemonPlistName = "com.kkrainbow.easytier.mac.helper.plist"
    public static let protocolVersion = "2"
    public static let pingPayload = "pong:\(protocolVersion)"
}

public enum PermissionState: String, Codable, Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    case notFound
    case error
}

@objc(EasyTierPrivilegedServiceProtocol)
public protocol EasyTierPrivilegedServiceProtocol {
    func ping(reply: @escaping (String?, String?) -> Void)
    func repairUserStateDirectory(uid: Int32, gid: Int32, home: String, reply: @escaping (String?, String?) -> Void)
    func validate(toml: String, reply: @escaping (String?, String?) -> Void)
    func run(configTOML: String, reply: @escaping (String?, String?) -> Void)
    func stop(instanceNames: [String], reply: @escaping (String?, String?) -> Void)
    func retain(instanceNames: [String], reply: @escaping (String?, String?) -> Void)
    func listInstances(reply: @escaping (String?, String?) -> Void)
    func collectNetworkInfos(reply: @escaping (String?, String?) -> Void)
}

public enum PrivilegedHelperError: LocalizedError, Equatable {
    case unavailable
    case helperReported(String)
    case invalidPayload(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "EasyTier privileged helper is not installed or not enabled. Install the helper before starting TUN networking."
        case let .helperReported(message):
            message
        case let .invalidPayload(message):
            "Invalid privileged helper response: \(message)"
        }
    }
}
