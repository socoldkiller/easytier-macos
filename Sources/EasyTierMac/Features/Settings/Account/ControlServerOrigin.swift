import Foundation

struct ControlServerOrigin: Hashable, Sendable {
    let url: URL

    init(_ input: String, allowsInsecureLocalhost: Bool = Self.defaultAllowsInsecureLocalhost) throws {
        guard var components = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            throw BrowserSSOError.invalidServerAddress
        }

        let isSecure = scheme == "https"
        let isLocalDevelopment = allowsInsecureLocalhost
            && scheme == "http"
            && Self.localhostNames.contains(host)
        guard isSecure || isLocalDevelopment,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            throw BrowserSSOError.invalidServerAddress
        }

        components.scheme = scheme
        components.host = host
        components.path = ""
        guard let url = components.url else {
            throw BrowserSSOError.invalidServerAddress
        }
        self.url = url
    }

    func appending(path: String) throws -> URL {
        guard path.hasPrefix("/"),
              !path.hasPrefix("//"),
              let relative = URL(string: path, relativeTo: url),
              let absolute = relative.absoluteURL as URL?,
              absolute.scheme == url.scheme,
              absolute.host == url.host,
              absolute.port == url.port
        else {
            throw BrowserSSOError.invalidBootstrap
        }
        return absolute
    }

    func contains(_ candidate: URL?) -> Bool {
        guard let candidate else { return false }
        return candidate.scheme?.lowercased() == url.scheme?.lowercased()
            && candidate.host?.lowercased() == url.host?.lowercased()
            && candidate.port == url.port
            && candidate.user == nil
            && candidate.password == nil
    }

    private static let localhostNames = ["localhost", "127.0.0.1", "::1"]

    private static var defaultAllowsInsecureLocalhost: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
