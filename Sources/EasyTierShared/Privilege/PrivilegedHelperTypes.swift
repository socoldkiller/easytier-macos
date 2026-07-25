import Foundation

package enum EasyTierPrivilegedHelperConstants {
    package static let appBundleIdentifier = "com.kkrainbow.easytier.mac"
    package static let bundleIdentifier = "com.kkrainbow.easytier.mac.helper"
    package static let machServiceName = "com.kkrainbow.easytier.mac.helper"
    package static let launchDaemonPlistName = "com.kkrainbow.easytier.mac.helper.plist"
    package static let protocolVersion = "17"
    package static let pingPayload = "pong:\(protocolVersion)"
}

package struct PrivilegedHelperErrorPayload: Codable, Equatable, Sendable {
    package var code: String
    package var message: String
    package var recoverySuggestion: String?

    package init(code: String, message: String, recoverySuggestion: String? = nil) {
        self.code = code
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }

    package func encodedString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    package static func decode(from string: String) throws -> PrivilegedHelperErrorPayload {
        try JSONDecoder().decode(PrivilegedHelperErrorPayload.self, from: Data(string.utf8))
    }
}

package enum HelperBuildMetadataError: LocalizedError, Equatable {
    case missingValue(String)

    package var errorDescription: String? {
        switch self {
        case let .missingValue(key):
            "Required helper build metadata is missing: \(key)."
        }
    }
}

package struct PrivilegedHelperBuildInfo: Codable, Equatable, Sendable {
    package var version: String
    package var build: String
    package var buildTime: String
    package var guiCommit: String
    package var coreVersion: String
    package var coreCommit: String
    package var protocolVersion: String

    package init(infoDictionary: [String: Any]) throws {
        version = try Self.value(named: "CFBundleShortVersionString", in: infoDictionary)
        build = try Self.value(named: "CFBundleVersion", in: infoDictionary)
        buildTime = try Self.value(named: "EasyTierBuildTime", in: infoDictionary)
        guiCommit = try Self.value(named: "EasyTierGUICommit", in: infoDictionary)
        coreVersion = try Self.value(named: "EasyTierCoreTag", in: infoDictionary)
        coreCommit = try Self.value(named: "EasyTierCoreCommit", in: infoDictionary)
        protocolVersion = EasyTierPrivilegedHelperConstants.protocolVersion
    }

    package init(bundle: Bundle) throws {
        try self.init(infoDictionary: bundle.infoDictionary ?? [:])
    }

    package var easyTierHelperDisplay: String {
        Self.componentDisplay(version: coreVersion, commit: coreCommit)
    }

    package var binaryDisplay: String {
        "\(version) (\(build)) · protocol \(protocolVersion)"
    }

    private static func value(named key: String, in info: [String: Any]) throws -> String {
        guard let value = info[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw HelperBuildMetadataError.missingValue(key) }
        return value
    }

    private static func abbreviated(_ value: String) -> String {
        let revision = value.hasSuffix("-dirty") ? String(value.dropLast(6)) : value
        let suffix = value.hasSuffix("-dirty") ? "-dirty" : ""
        guard revision.count == 40, revision.allSatisfy(\.isHexDigit) else { return value }
        return "\(revision.prefix(8))\(suffix)"
    }

    private static func componentDisplay(version: String, commit: String) -> String {
        let commit = abbreviated(commit)
        return "\(version) · \(commit)"
    }
}

@objc(EasyTierPrivilegedServiceProtocol)
package protocol EasyTierPrivilegedServiceProtocol {
    func ping(reply: @escaping (String?, String?) -> Void)
    func buildInfo(reply: @escaping (String?, String?) -> Void)
    func validate(toml: String, reply: @escaping (String?, String?) -> Void)
    func run(configTOML: String, reply: @escaping (String?, String?) -> Void)
    func stop(instanceNames: [String], reply: @escaping (String?, String?) -> Void)
    func retain(instanceNames: [String], reply: @escaping (String?, String?) -> Void)
    func collectNetworkInfos(reply: @escaping (String?, String?) -> Void)
    func configureRPCPortal(rpcPortal: String?, whitelist: [String]?, reply: @escaping (String?, String?) -> Void)
    func callJSONRPC(clientID: String, url: String, service: String, method: String, domain: String?, payload: String, reply: @escaping (String?, String?) -> Void)
    func shutdown(reply: @escaping (String?, String?) -> Void)
}

package enum PrivilegedHelperConnectionEvent: Sendable {
    case interrupted
    case invalidated
}

package enum PrivilegedHelperError: LocalizedError, Equatable {
    case unavailable
    case needsRegistration
    case helperReported(PrivilegedHelperErrorPayload)
    case invalidPayload(String)

    package var errorDescription: String? {
        switch self {
        case .unavailable:
            "EasyTier privileged helper is not installed or not enabled. Install the helper before starting a network."
        case .needsRegistration:
            "EasyTier needs background permission to run network instances. Approve EasyTier in System Settings > Login Items & Extensions, then start the network again."
        case let .helperReported(payload):
            if let recoverySuggestion = payload.recoverySuggestion?.trimmingCharacters(in: .whitespacesAndNewlines),
               !recoverySuggestion.isEmpty {
                "\(payload.message)\n\(recoverySuggestion)"
            } else {
                payload.message
            }
        case let .invalidPayload(message):
            "Invalid privileged helper response: \(message)"
        }
    }
}
