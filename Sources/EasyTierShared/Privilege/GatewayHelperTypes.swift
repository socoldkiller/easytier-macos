import Foundation

package enum GatewayPrivilegedHelperConstants {
    package static let bundleIdentifier = "com.coldkiller.gateway.helper"
    package static let machServiceName = "com.coldkiller.gateway.helper"
    package static let launchDaemonPlistName = "com.coldkiller.gateway.helper.plist"
    package static let protocolVersion = "6"
    package static let pingPayload = "pong:\(protocolVersion)"
}

package struct GatewayHelperBuildInfo: Codable, Equatable, Sendable {
    package var version: String
    package var build: String
    package var buildTime: String
    package var gatewayVersion: String
    package var gatewayCommit: String
    package var schemaVersion: UInt32
    package var protocolVersion: String

    package init(infoDictionary: [String: Any]) {
        version = Self.value(named: "CFBundleShortVersionString", in: infoDictionary, fallback: "Development")
        build = Self.value(named: "CFBundleVersion", in: infoDictionary, fallback: "0")
        buildTime = Self.value(named: "GatewayBuildTime", in: infoDictionary, fallback: "unknown")
        gatewayVersion = Self.value(named: "GatewayVersion", in: infoDictionary, fallback: "Development")
        gatewayCommit = Self.value(named: "GatewayCommit", in: infoDictionary, fallback: "unknown")
        schemaVersion = GatewaySchema.version
        protocolVersion = GatewayPrivilegedHelperConstants.protocolVersion
    }

    package init(bundle: Bundle) {
        self.init(infoDictionary: bundle.infoDictionary ?? [:])
    }

    package var componentDisplay: String {
        let commit = Self.abbreviated(gatewayCommit)
        let values = [gatewayVersion == "unknown" ? nil : gatewayVersion, commit == "unknown" ? nil : commit]
            .compactMap(\.self)
        let source = values.isEmpty ? "unknown" : values.joined(separator: " · ")
        return "\(source) · schema \(schemaVersion)"
    }

    package var binaryDisplay: String {
        "\(version) (\(build)) · protocol \(protocolVersion)"
    }

    private static func value(named key: String, in info: [String: Any], fallback: String) -> String {
        guard let value = info[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return fallback }
        return value
    }

    private static func abbreviated(_ value: String) -> String {
        let revision = value.hasSuffix("-dirty") ? String(value.dropLast(6)) : value
        let suffix = value.hasSuffix("-dirty") ? "-dirty" : ""
        guard revision.count == 40, revision.allSatisfy(\.isHexDigit) else { return value }
        return "\(revision.prefix(8))\(suffix)"
    }
}

@objc(GatewayPrivilegedServiceProtocol)
package protocol GatewayPrivilegedServiceProtocol {
    func ping(reply: @escaping (String?, String?) -> Void)
    func buildInfo(reply: @escaping (String?, String?) -> Void)
    func start(
        configurationJSON: String,
        secretsJSON: String,
        reply: @escaping (String?, String?) -> Void
    )
    func apply(
        configurationJSON: String,
        secretsJSON: String,
        reply: @escaping (String?, String?) -> Void
    )
    func stop(reply: @escaping (String?, String?) -> Void)
    func status(reply: @escaping (String?, String?) -> Void)
    func requestRenewal(certificateID: String?, reply: @escaping (String?, String?) -> Void)
    func setRetainsRuntimeAfterDisconnect(_ retainsRuntime: Bool, reply: @escaping (String?, String?) -> Void)
    func shutdown(reply: @escaping (String?, String?) -> Void)
}
