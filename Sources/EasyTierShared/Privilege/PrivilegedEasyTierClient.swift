import Foundation
import ServiceManagement

public final class PrivilegedEasyTierClient: EasyTierCoreClient, @unchecked Sendable {
    private let connectionLock = NSLock()
    private var _connection: NSXPCConnection?

    public init() {}

    deinit {
        let conn = _connection
        _connection = nil
        conn?.invalidate()
    }

    private func acquireConnection() throws -> NSXPCConnection {
        connectionLock.lock()
        defer { connectionLock.unlock() }

        if let conn = _connection {
            return conn
        }

        // SMAppService.status triggers a synchronous XPC round-trip to the
        // system daemon (smd), which is expensive. Only pay that cost when we
        // are about to open a fresh connection. Once a cached NSXPCConnection
        // exists, the helper's liveness is already observable through the
        // proxy error handler in callHelperReturningPayload, which drops the
        // connection and re-checks status on failure — so this guard is not
        // needed on every poll.
        try ensureHelperIsEnabled()

        let conn = NSXPCConnection(
            machServiceName: EasyTierPrivilegedHelperConstants.machServiceName,
            options: [.privileged]
        )
        conn.remoteObjectInterface = NSXPCInterface(with: EasyTierPrivilegedServiceProtocol.self)
        conn.resume()
        _connection = conn
        return conn
    }

    private func dropConnection() {
        connectionLock.lock()
        let conn = _connection
        _connection = nil
        connectionLock.unlock()
        conn?.invalidate()
    }

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

    public func configureRPCPortal(_ rpcPortal: String?, whitelist: [String]?) async throws {
        try await callHelper { service, reply in
            service.configureRPCPortal(rpcPortal: rpcPortal, whitelist: whitelist, reply: reply)
        }
    }

    public func callJSONRPC(service: String, method: String, domain: String?, payload: String) async throws -> String {
        try await callJSONRPC(clientID: "default", service: service, method: method, domain: domain, payload: payload)
    }

    public func connectRPCClient(clientID: String, url: URL) async throws {
        try await callHelper { service, reply in
            service.connectRPCClient(clientID: clientID, url: url.absoluteString, reply: reply)
        }
    }

    public func disconnectRPCClient(clientID: String) async throws {
        try await callHelper { service, reply in
            service.disconnectRPCClient(clientID: clientID, reply: reply)
        }
    }

    public func callJSONRPC(clientID: String, service: String, method: String, domain: String?, payload: String) async throws -> String {
        try await callHelperReturningPayload(timeoutError: Self.rpcTimeoutError) { helper, reply in
            helper.callJSONRPC(clientID: clientID, service: service, method: method, domain: domain, payload: payload, reply: reply)
        }
    }

    public func startConfigServerClient(url: URL) async throws {
        throw unsupported("Config-server client mode")
    }

    public func stopConfigServerClient() async throws {
        // Core v2.6.4 has no config-server client in this helper; stopping is a no-op.
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
        try await callHelperReturningPayload(timeoutError: Self.timeoutError, body)
    }

    private func callHelperReturningPayload(timeoutError: @escaping @Sendable () -> PrivilegedHelperError, _ body: @escaping (EasyTierPrivilegedServiceProtocol, @escaping (String?, String?) -> Void) -> Void) async throws -> String {
        do {
            return try await performHelperCall(timeoutError: timeoutError, body: body, isRetry: false)
        } catch PrivilegedHelperError.unavailable {
            // Daemon may have idle-exited even though it is still registered.
            // Drop the cached connection and retry once — launchd will relaunch the helper.
            dropConnection()
            return try await performHelperCall(timeoutError: timeoutError, body: body, isRetry: true)
        }
    }

    private func performHelperCall(
        timeoutError: @escaping @Sendable () -> PrivilegedHelperError,
        body: @escaping (EasyTierPrivilegedServiceProtocol, @escaping (String?, String?) -> Void) -> Void,
        isRetry: Bool
    ) async throws -> String {
        let connection = try acquireConnection()

        return try await withCheckedThrowingContinuation { continuation in
            let state = HelperCallState(continuation: continuation)
            let timeoutWork = DispatchWorkItem { [weak state] in
                state?.finish(.failure(timeoutError()))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeoutWork)

            let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                timeoutWork.cancel()
                self?.dropConnection()
                if LegacyPrivilegedHelperService.shouldUseLegacyInstaller {
                    if LegacyPrivilegedHelperService.isInstalled, !isRetry {
                        state.finish(.failure(PrivilegedHelperError.unavailable))
                    } else {
                        state.finish(.failure(LegacyPrivilegedHelperService.isInstalled ? Self.helperUnavailableError() : Self.legacyNeedsInstallError()))
                    }
                    return
                }

                let status = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName).status
                if status == .enabled, !isRetry {
                    state.finish(.failure(PrivilegedHelperError.unavailable))
                } else {
                    state.finish(.failure(status == .enabled ? Self.helperUnavailableError() : Self.statusError(status)))
                }
            }
            guard let service = proxy as? EasyTierPrivilegedServiceProtocol else {
                timeoutWork.cancel()
                dropConnection()
                if LegacyPrivilegedHelperService.shouldUseLegacyInstaller {
                    if LegacyPrivilegedHelperService.isInstalled, !isRetry {
                        state.finish(.failure(PrivilegedHelperError.unavailable))
                    } else {
                        state.finish(.failure(LegacyPrivilegedHelperService.isInstalled ? Self.helperUnavailableError() : Self.legacyNeedsInstallError()))
                    }
                    return
                }

                let status = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName).status
                if status == .enabled, !isRetry {
                    state.finish(.failure(PrivilegedHelperError.unavailable))
                } else {
                    state.finish(.failure(status == .enabled ? Self.helperUnavailableError() : Self.statusError(status)))
                }
                return
            }
            body(service) { payload, error in
                timeoutWork.cancel()
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

    private static let decoder = JSONDecoder()

    private func unsupported(_ feature: String) -> EasyTierCoreError {
        .operationFailed("\(feature) is not available through the privileged helper with EasyTier Core v2.6.4 FFI.")
    }

    private func ensureHelperIsEnabled() throws {
        if LegacyPrivilegedHelperService.shouldUseLegacyInstaller {
            if LegacyPrivilegedHelperService.isInstalled {
                return
            }
            throw Self.legacyNeedsInstallError()
        }

        let service = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName)
        let status = service.status
        switch status {
        case .enabled:
            return
        case .notRegistered:
            throw PrivilegedHelperError.needsRegistration
        default:
            throw Self.statusError(status)
        }
    }

    private static func timeoutError() -> PrivilegedHelperError {
        if LegacyPrivilegedHelperService.shouldUseLegacyInstaller {
            if !LegacyPrivilegedHelperService.isInstalled {
                return legacyNeedsInstallError()
            }
            return helperUnavailableError()
        }

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

    private static func rpcTimeoutError() -> PrivilegedHelperError {
        if LegacyPrivilegedHelperService.shouldUseLegacyInstaller {
            if !LegacyPrivilegedHelperService.isInstalled {
                return legacyNeedsInstallError()
            }
            return helperUnavailableError()
        }

        let service = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName)
        if service.status != .enabled {
            return statusError(service.status)
        }

        return .helperReported(
            PrivilegedHelperErrorPayload(
                code: "remoteRPCTimeout",
                message: "Remote EasyTier RPC did not respond within 15 seconds.",
                recoverySuggestion: "Check that the remote device is online, rpc_portal is enabled, and the RPC URL uses the EasyTier virtual IP."
            )
        )
    }

    private static func helperUnavailableError() -> PrivilegedHelperError {
        .helperReported(
            PrivilegedHelperErrorPayload(
                code: "helperUnavailable",
                message: "Privileged helper is enabled but is not responding.",
                recoverySuggestion: "Quit and reopen EasyTier. If this continues, reinstall the helper."
            )
        )
    }

    private static func legacyNeedsInstallError() -> PrivilegedHelperError {
        .helperReported(
            PrivilegedHelperErrorPayload(
                code: "helperNeedsAdministratorInstall",
                message: "EasyTier needs administrator permission to install the privileged helper.",
                recoverySuggestion: "Click Install Helper and enter an administrator password, then start the network again."
            )
        )
    }

    private static func statusError(_ status: SMAppService.Status) -> PrivilegedHelperError {
        switch status {
        case .notRegistered:
            .needsRegistration
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
    private let continuation: CheckedContinuation<String, Error>

    init(continuation: CheckedContinuation<String, Error>) {
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

        switch result {
        case let .success(payload):
            continuation.resume(returning: payload)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
