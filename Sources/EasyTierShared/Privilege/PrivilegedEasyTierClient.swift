import Foundation
import ServiceManagement

package final class PrivilegedEasyTierClient: EasyTierCoreClient, EasyTierHelperShutdownClient, @unchecked Sendable {
    private static let defaultCallTimeout: Duration = .seconds(15)
    private static let registrationProbeTimeout: Duration = .seconds(3)

    // NSXPCConnection is not Sendable; every access to the cached connection is lock-protected.
    private let connectionLock = NSLock()
    private var _connection: NSXPCConnection?

    package init() {}

    deinit {
        dropConnection()
    }

    private func acquireConnection() throws -> NSXPCConnection {
        connectionLock.lock()
        defer { connectionLock.unlock() }

        if let conn = _connection {
            return conn
        }

        // XPC is the readiness signal; SMAppService.status is only consulted
        // after a proxy error because its snapshot can lag registration.
        let conn = NSXPCConnection(
            machServiceName: EasyTierPrivilegedHelperConstants.machServiceName,
            options: [.privileged]
        )
        let requirement = try EasyTierXPCCodeSigningRequirements.requirement(
            forPeerIdentifier: EasyTierPrivilegedHelperConstants.bundleIdentifier
        )
        conn.setCodeSigningRequirement(requirement)
        conn.remoteObjectInterface = NSXPCInterface(with: EasyTierPrivilegedServiceProtocol.self)
        conn.interruptionHandler = { [weak self, weak conn] in
            guard let conn else { return }
            self?.connectionDidEnd(conn)
        }
        conn.invalidationHandler = { [weak self, weak conn] in
            guard let conn else { return }
            self?.connectionDidEnd(conn)
        }
        _connection = conn
        conn.activate()
        return conn
    }

    private func dropConnection(_ expectedConnection: NSXPCConnection? = nil) {
        connectionLock.lock()
        let conn: NSXPCConnection?
        if let expectedConnection, _connection !== expectedConnection {
            conn = expectedConnection
        } else {
            conn = _connection
            _connection = nil
        }
        connectionLock.unlock()
        conn?.invalidate()
    }

    private func connectionDidEnd(_ connection: NSXPCConnection) {
        connectionLock.lock()
        if _connection === connection {
            _connection = nil
        }
        connectionLock.unlock()
    }

    package func validate(toml: String) async throws {
        try await callHelper { service, reply in
            service.validate(toml: toml, reply: reply)
        }
    }

    package func run(toml: String) async throws {
        try await callHelper { service, reply in
            service.run(configTOML: toml, reply: reply)
        }
    }

    package func stop(instanceNames: [String]) async throws {
        try await callHelper { service, reply in
            service.stop(instanceNames: instanceNames, reply: reply)
        }
    }

    package func retain(instanceNames: [String]) async throws {
        try await callHelper { service, reply in
            service.retain(instanceNames: instanceNames, reply: reply)
        }
    }

    package func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] {
        do {
            let payload = try await callHelperReturningPayload { service, reply in
                service.collectNetworkInfos(reply: reply)
            }
            return try JSONDecoder().decode([String: NetworkInstanceRunningInfo].self, from: Data(payload.utf8))
        } catch let error as DecodingError {
            throw PrivilegedHelperError.invalidPayload(String(describing: error))
        }
    }

    package func configureRPCPortal(_ rpcPortal: String?, whitelist: [String]?) async throws {
        try await callHelper { service, reply in
            service.configureRPCPortal(rpcPortal: rpcPortal, whitelist: whitelist, reply: reply)
        }
    }

    package func callJSONRPC(
        clientID: String,
        url: URL,
        service: String,
        method: String,
        domain: String?,
        payload: String
    ) async throws -> String {
        try await callHelperReturningPayload(timeout: Self.defaultCallTimeout, timeoutError: Self.rpcTimeoutError) { helper, reply in
            helper.callJSONRPC(
                clientID: clientID,
                url: url.absoluteString,
                service: service,
                method: method,
                domain: domain,
                payload: payload,
                reply: reply
            )
        }
    }

    package func helperPingPayload() async throws -> String {
        try await helperPingPayload(
            timeout: Self.defaultCallTimeout,
            timeoutError: Self.timeoutError
        )
    }

    package func probeHelperAvailability() async throws {
        _ = try await helperPingPayload(
            timeout: Self.registrationProbeTimeout,
            timeoutError: Self.registrationProbeTimeoutError
        )
    }

    private func helperPingPayload(
        timeout: Duration,
        timeoutError: @escaping @Sendable () -> PrivilegedHelperError
    ) async throws -> String {
        let payload = try await callHelperReturningPayload(timeout: timeout, timeoutError: timeoutError) { service, reply in
            service.ping(reply: reply)
        }
        guard payload == EasyTierPrivilegedHelperConstants.pingPayload else {
            throw PrivilegedHelperError.helperReported(
                PrivilegedHelperErrorPayload(
                    code: "protocolMismatch",
                    message: "Privileged helper is registered but does not match this app version.",
                    recoverySuggestion: "Reinstall the privileged helper from this EasyTier app."
                )
            )
        }
        return payload
    }

    package func shutdownHelper() async throws {
        try await callHelper { service, reply in
            service.shutdown(reply: reply)
        }
        dropConnection()
    }

    private func callHelper(_ body: @escaping (EasyTierPrivilegedServiceProtocol, @escaping (String?, String?) -> Void) -> Void) async throws {
        _ = try await callHelperReturningPayload(body)
    }

    private func callHelperReturningPayload(_ body: @escaping (EasyTierPrivilegedServiceProtocol, @escaping (String?, String?) -> Void) -> Void) async throws -> String {
        try await callHelperReturningPayload(timeout: Self.defaultCallTimeout, timeoutError: Self.timeoutError, body)
    }

    private func callHelperReturningPayload(
        timeout: Duration,
        timeoutError: @escaping @Sendable () -> PrivilegedHelperError,
        _ body: @escaping (EasyTierPrivilegedServiceProtocol, @escaping (String?, String?) -> Void) -> Void
    ) async throws -> String {
        do {
            return try await performHelperCall(timeout: timeout, timeoutError: timeoutError, body: body, isRetry: false)
        } catch PrivilegedHelperError.unavailable {
            // Daemon may have idle-exited even though it is still registered.
            // The failed call already invalidated its exact connection. Retry
            // once so launchd can relaunch the registered helper.
            return try await performHelperCall(timeout: timeout, timeoutError: timeoutError, body: body, isRetry: true)
        }
    }

    private func performHelperCall(
        timeout: Duration,
        timeoutError: @escaping @Sendable () -> PrivilegedHelperError,
        body: @escaping (EasyTierPrivilegedServiceProtocol, @escaping (String?, String?) -> Void) -> Void,
        isRetry: Bool
    ) async throws -> String {
        let connection = try acquireConnection()
        let state = HelperCallState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.install(continuation) else { return }
                // The timeout must not inherit a UI caller's MainActor isolation.
                let timeoutTask = Task.detached { [weak state] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    state?.finish(.failure(timeoutError()))
                }
                state.setTimeoutTask(timeoutTask)

                let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                    self?.dropConnection(connection)
                    state.finish(.failure(Self.connectionFailure(isRetry: isRetry)))
                }
                guard let service = proxy as? EasyTierPrivilegedServiceProtocol else {
                    dropConnection(connection)
                    state.finish(.failure(Self.connectionFailure(isRetry: isRetry)))
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
        } onCancel: {
            state.finish(.failure(CancellationError()))
        }
    }

    private static func connectionFailure(isRetry: Bool) -> PrivilegedHelperError {
        if LegacyPrivilegedHelperService.shouldUseLegacyInstaller {
            if LegacyPrivilegedHelperService.isInstalled, !isRetry {
                return .unavailable
            }
            return LegacyPrivilegedHelperService.isInstalled ? helperUnavailableError() : legacyNeedsInstallError()
        }

        let status = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName).status
        if status == .enabled, !isRetry {
            return .unavailable
        }
        return status == .enabled ? helperUnavailableError() : statusError(status)
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

    private static func registrationProbeTimeoutError() -> PrivilegedHelperError {
        if LegacyPrivilegedHelperService.shouldUseLegacyInstaller {
            return LegacyPrivilegedHelperService.isInstalled ? helperUnavailableError() : legacyNeedsInstallError()
        }

        let service = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName)
        if service.status != .enabled {
            return statusError(service.status)
        }

        return .helperReported(
            PrivilegedHelperErrorPayload(
                code: "helperProbeTimeout",
                message: "Privileged helper was registered but did not become reachable.",
                recoverySuggestion: "Try starting the network again. If this continues, quit and reopen EasyTier."
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
                    recoverySuggestion: "Click Install Helper before starting a network."
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
    private var continuation: CheckedContinuation<String, Error>?
    private var pendingResult: Result<String, Error>?
    private var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<String, Error>) -> Bool {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            resume(continuation, with: pendingResult)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if didFinish {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        let timeoutTask = timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        guard let continuation else { return }
        resume(continuation, with: result)
    }

    private func resume(
        _ continuation: CheckedContinuation<String, Error>,
        with result: Result<String, Error>
    ) {
        switch result {
        case let .success(payload):
            continuation.resume(returning: payload)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
