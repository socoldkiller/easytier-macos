import Foundation
import ServiceManagement

public final class PrivilegedEasyTierClient: EasyTierCoreClient, @unchecked Sendable {
    public init() {}

    public func version() async throws -> String {
        let payload = try await helperPingPayload()
        guard payload == EasyTierPrivilegedHelperConstants.pingPayload else {
            throw PrivilegedHelperError.helperReported(
                PrivilegedHelperErrorPayload(
                    code: "protocolMismatch",
                    message: "Privileged helper is registered but did not match this app version.",
                    recoverySuggestion: "Reinstall the privileged helper from this EasyTier app."
                )
            )
        }
        return "EasyTier privileged helper"
    }

    public func validate(toml: String) async throws {
        try await callHelper { service, reply in
            service.validate(toml: toml, reply: reply)
        }
    }

    public func run(config: NetworkConfig) async throws {
        let toml = try NetworkConfigTOMLCodec.encode(config)
        try await validate(toml: toml)
        try await callHelper { service, reply in
            service.run(configTOML: toml, reply: reply)
        }
    }

    public func stop(instanceNames: [String]) async throws {
        try await callHelper { service, reply in
            service.stop(instanceNames: instanceNames, reply: reply)
        }
    }

    public func retain(instanceNames: [String]) async throws {
        try await callHelper { service, reply in
            service.retain(instanceNames: instanceNames, reply: reply)
        }
    }

    public func listInstances() async throws -> [NetworkInstance] {
        do {
            let payload = try await callHelperReturningPayload { service, reply in
                service.listInstances(reply: reply)
            }
            return try Self.decoder.decode([NetworkInstance].self, from: Data(payload.utf8))
        } catch let error as DecodingError {
            throw PrivilegedHelperError.invalidPayload(String(describing: error))
        }
    }

    public func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] {
        do {
            let payload = try await callHelperReturningPayload { service, reply in
                service.collectNetworkInfos(reply: reply)
            }
            return try Self.decoder.decode([String: NetworkInstanceRunningInfo].self, from: Data(payload.utf8))
        } catch let error as DecodingError {
            throw PrivilegedHelperError.invalidPayload(String(describing: error))
        }
    }

    public func callJSONRPC(service: String, method: String, domain: String?, payload: String) async throws -> String {
        throw unsupported("JSON-RPC bridge")
    }

    public func startConfigServerClient(url: URL) async throws {
        throw unsupported("Config-server client mode")
    }

    public func stopConfigServerClient() async throws {
        throw unsupported("Config-server client mode")
    }

    public func isConfigServerClientConnected() async throws -> Bool {
        throw unsupported("Config-server client mode")
    }

    public func helperPingPayload() async throws -> String {
        do {
            return try await callHelperReturningPayload { service, reply in service.ping(reply: reply) }
        } catch PrivilegedHelperError.unavailable {
            throw PrivilegedHelperError.unavailable
        }
    }

    private func callHelper(_ body: @escaping (EasyTierPrivilegedServiceProtocol, @escaping (String?, String?) -> Void) -> Void) async throws {
        _ = try await callHelperReturningPayload(body)
    }

    private func callHelperReturningPayload(_ body: @escaping (EasyTierPrivilegedServiceProtocol, @escaping (String?, String?) -> Void) -> Void) async throws -> String {
        try ensureHelperIsEnabled()

        let connection = Self.makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let state = HelperCallState(connection: connection, continuation: continuation)

            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                state.finish(.failure(Self.timeoutError()))
            }

            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                let status = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName).status
                state.finish(.failure(status == .enabled ? PrivilegedHelperError.unavailable : Self.statusError(status)))
            }
            guard let service = proxy as? EasyTierPrivilegedServiceProtocol else {
                let status = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName).status
                state.finish(.failure(status == .enabled ? PrivilegedHelperError.unavailable : Self.statusError(status)))
                return
            }
            body(service) { payload, error in
                if let error, !error.isEmpty {
                    state.finish(.failure(PrivilegedHelperError.helperReported(PrivilegedHelperErrorPayload.decode(from: error))))
                } else if let payload {
                    state.finish(.success(payload))
                } else {
                    state.finish(.failure(PrivilegedHelperError.invalidPayload("Helper returned no payload.")))
                }
            }
        }
    }

    private static func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: EasyTierPrivilegedHelperConstants.machServiceName,
            options: [.privileged]
        )
        connection.remoteObjectInterface = NSXPCInterface(with: EasyTierPrivilegedServiceProtocol.self)
        connection.resume()
        return connection
    }

    private static let decoder = JSONDecoder()

    private func unsupported(_ feature: String) -> EasyTierCoreError {
        .operationFailed("\(feature) is not available through the privileged helper with EasyTier Core v2.6.4 FFI.")
    }

    private func ensureHelperIsEnabled() throws {
        let service = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName)
        guard service.status == .enabled else {
            throw Self.statusError(service.status)
        }
    }

    private static func timeoutError() -> PrivilegedHelperError {
        let service = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName)
        if service.status != .enabled {
            return statusError(service.status)
        }

        return .helperReported(
            PrivilegedHelperErrorPayload(
                code: "helperTimeout",
                message: "Privileged helper is enabled but did not respond within 15 seconds.",
                recoverySuggestion: "Quit and reopen EasyTier, then try installing the helper again. If this continues, remove and reinstall EasyTier."
            )
        )
    }

    private static func statusError(_ status: SMAppService.Status) -> PrivilegedHelperError {
        switch status {
        case .notRegistered:
            .helperReported(
                PrivilegedHelperErrorPayload(
                    code: "helperNotRegistered",
                    message: "Privileged helper is not installed.",
                    recoverySuggestion: "Click Install Helper before starting TUN networking."
                )
            )
        case .requiresApproval:
            .helperReported(
                PrivilegedHelperErrorPayload(
                    code: "helperRequiresApproval",
                    message: "Privileged helper is installed but macOS has not allowed it to run in the background.",
                    recoverySuggestion: "Open System Settings > General > Login Items & Extensions, allow EasyTier, then return to EasyTier and try again."
                )
            )
        case .notFound:
            .helperReported(
                PrivilegedHelperErrorPayload(
                    code: "helperNotFound",
                    message: "Privileged helper registration is not initialized for this app bundle.",
                    recoverySuggestion: "Click Install Helper before starting TUN networking."
                )
            )
        case .enabled:
            .unavailable
        @unknown default:
            .helperReported(
                PrivilegedHelperErrorPayload(
                    code: "helperUnknownStatus",
                    message: "Privileged helper is in an unknown ServiceManagement state.",
                    recoverySuggestion: "Restart EasyTier and reinstall the helper."
                )
            )
        }
    }
}

private final class HelperCallState: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private let connection: NSXPCConnection
    private let continuation: CheckedContinuation<String, Error>

    init(connection: NSXPCConnection, continuation: CheckedContinuation<String, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()

        connection.invalidate()
        switch result {
        case let .success(payload):
            continuation.resume(returning: payload)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
