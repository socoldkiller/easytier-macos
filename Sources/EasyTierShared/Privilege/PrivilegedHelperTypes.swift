import Foundation

package enum EasyTierPrivilegedHelperConstants {
    package static let bundleIdentifier = "com.kkrainbow.easytier.mac.helper"
    package static let machServiceName = "com.kkrainbow.easytier.mac.helper"
    package static let launchDaemonPlistName = "com.kkrainbow.easytier.mac.helper.plist"
    package static let protocolVersion = "10"
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

    package func encodedString() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8)
        else { return message }
        return string
    }

    package static func decode(from string: String) -> PrivilegedHelperErrorPayload {
        if let data = string.data(using: .utf8),
           let payload = try? JSONDecoder().decode(PrivilegedHelperErrorPayload.self, from: data) {
            return payload
        }
        return PrivilegedHelperErrorPayload(code: "legacyHelperError", message: string)
    }
}

@objc(EasyTierPrivilegedServiceProtocol)
package protocol EasyTierPrivilegedServiceProtocol {
    func ping(reply: @escaping (String?, String?) -> Void)
    func validate(toml: String, reply: @escaping (String?, String?) -> Void)
    func run(configTOML: String, reply: @escaping (String?, String?) -> Void)
    func stop(instanceNames: [String], reply: @escaping (String?, String?) -> Void)
    func retain(instanceNames: [String], reply: @escaping (String?, String?) -> Void)
    func collectNetworkInfos(reply: @escaping (String?, String?) -> Void)
    func configureRPCPortal(rpcPortal: String?, whitelist: [String]?, reply: @escaping (String?, String?) -> Void)
    func callJSONRPC(clientID: String, url: String, service: String, method: String, domain: String?, payload: String, reply: @escaping (String?, String?) -> Void)
    func shutdown(reply: @escaping (String?, String?) -> Void)
}

package enum PrivilegedHelperError: LocalizedError, Equatable {
    case unavailable
    case needsRegistration
    case helperReported(PrivilegedHelperErrorPayload)
    case invalidPayload(String)

    package var errorDescription: String? {
        switch self {
        case .unavailable:
            "EasyTier privileged helper is not installed or not enabled. Install the helper before starting TUN networking."
        case .needsRegistration:
            "EasyTier needs background permission to create a TUN interface. Approve EasyTier in System Settings > Login Items & Extensions, then start the network again."
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
