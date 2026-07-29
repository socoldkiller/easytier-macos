import AppKit
import Foundation

struct BrowserSSOSignIn: Sendable {
    let username: String
    let configToken: String
    let configEndpoint: String
    let controlOrigin: URL
    let consoleURL: URL
}

actor BrowserSSOClient {
    func signIn(serverAddress: String) async throws -> BrowserSSOSignIn {
        let origin = try ControlServerOrigin(serverAddress)
        let bootstrap = try await fetchBootstrap(from: origin)
        let state = try NativeSSOSecureRandom.state()
        let callback = LoopbackSSOCallbackServer()
        let port = try await callback.start(expectedState: state)

        var loginComponents = URLComponents(url: bootstrap.loginURL, resolvingAgainstBaseURL: false)
        loginComponents?.queryItems = [
            URLQueryItem(name: "native_port", value: String(port)),
            URLQueryItem(name: "native_state", value: state),
        ]
        guard let loginURL = loginComponents?.url else {
            callback.cancel()
            throw BrowserSSOError.invalidBootstrap
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(loginURL) }
        guard opened else {
            callback.cancel()
            throw BrowserSSOError.browserCouldNotOpen
        }

        let ticket = try await waitForTicket(from: callback)
        return try await exchange(ticket: ticket, state: state, origin: origin, bootstrap: bootstrap)
    }

    func fetchBootstrap(from origin: ControlServerOrigin) async throws -> ValidatedClientBootstrap {
        let url = try origin.appending(path: "/.well-known/easytier-client")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request, origin: origin)
        guard data.count <= 64 * 1024,
              let http = response as? HTTPURLResponse,
              origin.contains(http.url)
        else {
            throw BrowserSSOError.invalidResponse
        }
        guard http.statusCode != 404 else {
            throw BrowserSSOError.serverDoesNotSupportAccountLogin
        }
        guard http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true
        else {
            throw BrowserSSOError.invalidResponse
        }
        return try JSONDecoder().decode(EasyTierClientBootstrap.self, from: data).validate(for: origin)
    }

    private func waitForTicket(from callback: LoopbackSSOCallbackServer) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await callback.waitForTicket() }
            group.addTask {
                try await Task.sleep(for: .seconds(180))
                throw BrowserSSOError.callbackTimedOut
            }
            defer {
                group.cancelAll()
                callback.cancel()
            }
            guard let ticket = try await group.next() else {
                throw BrowserSSOError.callbackTimedOut
            }
            return ticket
        }
    }

    private func exchange(
        ticket: String,
        state: String,
        origin: ControlServerOrigin,
        bootstrap: ValidatedClientBootstrap
    ) async throws -> BrowserSSOSignIn {
        var request = URLRequest(
            url: bootstrap.exchangeURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(NativeExchangeRequest(state: state, ticket: ticket))
        let (data, response) = try await perform(request, origin: origin)
        guard data.count <= 64 * 1024,
              let http = response as? HTTPURLResponse,
              origin.contains(http.url)
        else {
            throw BrowserSSOError.invalidResponse
        }
        guard http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true
        else {
            throw BrowserSSOError.signInRejected
        }
        let exchange = try JSONDecoder().decode(NativeExchangeResponse.self, from: data)
        guard exchange.configEndpoint == bootstrap.configEndpoint,
              exchange.consolePath == bootstrap.consoleURL.path,
              exchange.username == exchange.configToken,
              !exchange.username.isEmpty,
              exchange.username.count <= 128,
              !exchange.username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw BrowserSSOError.invalidResponse
        }
        return BrowserSSOSignIn(
            username: exchange.username,
            configToken: exchange.configToken,
            configEndpoint: exchange.configEndpoint,
            controlOrigin: origin.url,
            consoleURL: bootstrap.consoleURL
        )
    }

    private func perform(
        _ request: URLRequest,
        origin: ControlServerOrigin
    ) async throws -> (Data, URLResponse) {
        let redirectDelegate = SameOriginRedirectDelegate(origin: origin)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        let session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let response = try await session.data(for: request)
        guard !redirectDelegate.blockedRedirect else {
            throw BrowserSSOError.insecureRedirect
        }
        return response
    }
}

private final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: ControlServerOrigin
    private let lock = NSLock()
    private var didBlockRedirect = false

    init(origin: ControlServerOrigin) {
        self.origin = origin
    }

    var blockedRedirect: Bool {
        lock.withLock { didBlockRedirect }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard origin.contains(request.url) else {
            lock.withLock { didBlockRedirect = true }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private struct NativeExchangeRequest: Encodable {
    let state: String
    let ticket: String
}

private struct NativeExchangeResponse: Decodable {
    let username: String
    let configToken: String
    let configEndpoint: String
    let consolePath: String

    enum CodingKeys: String, CodingKey {
        case username
        case configToken = "config_token"
        case configEndpoint = "config_endpoint"
        case consolePath = "console_path"
    }
}
