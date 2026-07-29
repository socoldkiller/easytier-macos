import Foundation

struct EasyTierClientBootstrap: Decodable, Equatable, Sendable {
    let protocolVersion: Int
    let configEndpoint: String
    let loginPath: String
    let consolePath: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case configEndpoint = "config_endpoint"
        case loginPath = "login_path"
        case consolePath = "console_path"
    }

    func validate(for origin: ControlServerOrigin) throws -> ValidatedClientBootstrap {
        guard protocolVersion == 1 else {
            throw BrowserSSOError.unsupportedProtocolVersion
        }
        let endpoint = try Self.validatedConfigEndpoint(configEndpoint)
        let loginURL = try Self.validatedSameOriginPath(loginPath, origin: origin)
        let consoleURL = try Self.validatedSameOriginPath(consolePath, origin: origin)
        return ValidatedClientBootstrap(
            configEndpoint: endpoint,
            loginURL: loginURL,
            consoleURL: consoleURL
        )
    }

    private static func validatedSameOriginPath(
        _ path: String,
        origin: ControlServerOrigin
    ) throws -> URL {
        guard path.hasPrefix("/#/"),
              !path.contains("?"),
              !path.contains("\\")
        else {
            throw BrowserSSOError.invalidBootstrap
        }
        return try origin.appending(path: path)
    }

    private static func validatedConfigEndpoint(_ value: String) throws -> String {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "tcp",
              components.host != nil,
              components.port != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            throw BrowserSSOError.invalidBootstrap
        }
        return value
    }
}

struct ValidatedClientBootstrap: Equatable, Sendable {
    let configEndpoint: String
    let loginURL: URL
    let consoleURL: URL
}
