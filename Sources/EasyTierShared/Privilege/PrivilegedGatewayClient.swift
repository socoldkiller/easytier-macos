import Foundation
import ServiceManagement

package final class PrivilegedGatewayClient: GatewayClient, @unchecked Sendable {
    private static let defaultCallTimeout: Duration = .seconds(15)
    private static let operationTimeout: Duration = .seconds(45)
    private static let registrationProbeTimeout: Duration = .seconds(3)

    private let connectionLock = NSLock()
    private var connection: NSXPCConnection?
    private var eventContinuations: [UUID: AsyncStream<PrivilegedHelperConnectionEvent>.Continuation] = [:]

    package init() {}

    deinit {
        dropConnection()
    }

    package func start(configuration: GatewayConfiguration) async throws {
        let payload = try encodeValidated(configuration)
        try await call(timeout: Self.operationTimeout, timeoutError: { Self.operationTimeoutError("start") }) {
            $0.start(configurationJSON: payload, reply: $1)
        }
    }

    package func apply(configuration: GatewayConfiguration) async throws {
        let payload = try encodeValidated(configuration)
        try await call(timeout: Self.operationTimeout, timeoutError: { Self.operationTimeoutError("apply") }) {
            $0.apply(configurationJSON: payload, reply: $1)
        }
    }

    package func stop() async throws {
        try await call(timeout: Self.operationTimeout, timeoutError: { Self.operationTimeoutError("stop") }) {
            $0.stop(reply: $1)
        }
    }

    package func status() async throws -> GatewayStatus {
        let payload = try await callReturningPayload { $0.status(reply: $1) }
        do {
            return try JSONDecoder().decode(GatewayStatus.self, from: Data(payload.utf8))
        } catch {
            throw PrivilegedHelperError.invalidPayload("Failed to decode Gateway status: \(error.localizedDescription)")
        }
    }

    package func requestRenewal(certificateID: String?) async throws {
        try await call(timeout: Self.operationTimeout, timeoutError: { Self.operationTimeoutError("renewal") }) {
            $0.requestRenewal(certificateID: certificateID, reply: $1)
        }
    }

    package func connectionEvents() -> AsyncStream<PrivilegedHelperConnectionEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            connectionLock.lock()
            eventContinuations[id] = continuation
            connectionLock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeEventContinuation(id: id)
            }
        }
    }

    package func probeHelperAvailability() async throws {
        _ = try await ping(
            timeout: Self.registrationProbeTimeout,
            timeoutError: Self.registrationProbeTimeoutError
        )
    }

    package func helperPingPayload() async throws -> String {
        try await ping(timeout: Self.defaultCallTimeout, timeoutError: Self.timeoutError)
    }

    package func helperBuildInfo() async throws -> GatewayHelperBuildInfo {
        _ = try await ping(timeout: Self.defaultCallTimeout, timeoutError: Self.timeoutError)
        let payload = try await callReturningPayload { $0.buildInfo(reply: $1) }
        guard let data = payload.data(using: .utf8),
              let info = try? JSONDecoder().decode(GatewayHelperBuildInfo.self, from: data)
        else {
            throw PrivilegedHelperError.invalidPayload("Gateway helper build information is not valid JSON.")
        }
        return info
    }

    package func shutdownHelper() async throws {
        try await call { $0.shutdown(reply: $1) }
        dropConnection()
    }

    private func encodeValidated(_ configuration: GatewayConfiguration) throws -> String {
        let normalized = try GatewayConfigurationValidator.validate(configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(normalized)
        guard let string = String(data: data, encoding: .utf8) else {
            throw PrivilegedHelperError.invalidPayload("Failed to encode Gateway configuration as UTF-8 JSON.")
        }
        return string
    }

    private func ping(
        timeout: Duration,
        timeoutError: @escaping @Sendable () -> PrivilegedHelperError
    ) async throws -> String {
        let payload = try await callReturningPayload(timeout: timeout, timeoutError: timeoutError) {
            $0.ping(reply: $1)
        }
        guard payload == GatewayPrivilegedHelperConstants.pingPayload else {
            throw PrivilegedHelperError.helperReported(
                PrivilegedHelperErrorPayload(
                    code: "protocolMismatch",
                    message: "Gateway helper is registered but does not match this app version.",
                    recoverySuggestion: "Reinstall the Gateway helper from this app."
                )
            )
        }
        return payload
    }

    private func acquireConnection() throws -> NSXPCConnection {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        if let connection { return connection }

        let newConnection = NSXPCConnection(
            machServiceName: GatewayPrivilegedHelperConstants.machServiceName,
            options: [.privileged]
        )
        let requirement = try EasyTierXPCCodeSigningRequirements.requirement(
            forPeerIdentifier: GatewayPrivilegedHelperConstants.bundleIdentifier
        )
        newConnection.setCodeSigningRequirement(requirement)
        newConnection.remoteObjectInterface = NSXPCInterface(with: GatewayPrivilegedServiceProtocol.self)
        newConnection.interruptionHandler = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            handleConnectionEvent(.interrupted, connection: newConnection)
        }
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            handleConnectionEvent(.invalidated, connection: newConnection)
        }
        connection = newConnection
        newConnection.activate()
        return newConnection
    }

    private func dropConnection(_ expected: NSXPCConnection? = nil) {
        connectionLock.lock()
        let connectionToDrop: NSXPCConnection?
        if let expected, connection !== expected {
            connectionToDrop = expected
        } else {
            connectionToDrop = connection
            connection = nil
        }
        connectionLock.unlock()
        connectionToDrop?.interruptionHandler = nil
        connectionToDrop?.invalidationHandler = nil
        connectionToDrop?.invalidate()
    }

    private func call(
        _ body: @escaping (GatewayPrivilegedServiceProtocol, @escaping (String?, String?) -> Void) -> Void
    ) async throws {
        try await call(timeout: Self.defaultCallTimeout, timeoutError: Self.timeoutError, body)
    }

    private func call(
        timeout: Duration,
        timeoutError: @escaping @Sendable () -> PrivilegedHelperError,
        _ body: @escaping (GatewayPrivilegedServiceProtocol, @escaping (String?, String?) -> Void) -> Void
    ) async throws {
        _ = try await callReturningPayload(timeout: timeout, timeoutError: timeoutError, body)
    }

    private func callReturningPayload(
        _ body: @escaping (GatewayPrivilegedServiceProtocol, @escaping (String?, String?) -> Void) -> Void
    ) async throws -> String {
        try await callReturningPayload(timeout: Self.defaultCallTimeout, timeoutError: Self.timeoutError, body)
    }

    private func callReturningPayload(
        timeout: Duration,
        timeoutError: @escaping @Sendable () -> PrivilegedHelperError,
        _ body: @escaping (GatewayPrivilegedServiceProtocol, @escaping (String?, String?) -> Void) -> Void
    ) async throws -> String {
        do {
            return try await performCall(timeout: timeout, timeoutError: timeoutError, body: body, isRetry: false)
        } catch PrivilegedHelperError.unavailable {
            return try await performCall(timeout: timeout, timeoutError: timeoutError, body: body, isRetry: true)
        }
    }

    private func performCall(
        timeout: Duration,
        timeoutError: @escaping @Sendable () -> PrivilegedHelperError,
        body: @escaping (GatewayPrivilegedServiceProtocol, @escaping (String?, String?) -> Void) -> Void,
        isRetry: Bool
    ) async throws -> String {
        let activeConnection = try acquireConnection()
        let state = GatewayHelperCallState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.install(continuation) else { return }
                let timeoutTask = Task.detached { [weak state] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    state?.finish(.failure(timeoutError()))
                }
                state.setTimeoutTask(timeoutTask)
                let proxy = activeConnection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                    self?.dropConnection(activeConnection)
                    state.finish(.failure(Self.connectionFailure(isRetry: isRetry)))
                }
                guard let service = proxy as? GatewayPrivilegedServiceProtocol else {
                    dropConnection(activeConnection)
                    state.finish(.failure(Self.connectionFailure(isRetry: isRetry)))
                    return
                }
                body(service) { payload, error in
                    if let error, !error.isEmpty {
                        state.finish(.failure(PrivilegedHelperError.helperReported(PrivilegedHelperErrorPayload.decode(from: error))))
                    } else if let payload {
                        state.finish(.success(payload))
                    } else {
                        state.finish(.failure(PrivilegedHelperError.invalidPayload("Gateway helper returned no payload.")))
                    }
                }
            }
        } onCancel: {
            state.finish(.failure(CancellationError()))
        }
    }

    private static func connectionFailure(isRetry: Bool) -> PrivilegedHelperError {
        let status = serviceStatus
        if status == .enabled, !isRetry { return .unavailable }
        return status == .enabled ? unavailableError : statusError(status)
    }

    private static func timeoutError() -> PrivilegedHelperError {
        let status = serviceStatus
        guard status == .enabled else { return statusError(status) }
        return .helperReported(
            PrivilegedHelperErrorPayload(
                code: "gatewayHelperTimeout",
                message: "Gateway helper is enabled but did not respond within 15 seconds.",
                recoverySuggestion: "Quit and reopen the app, then reinstall the Gateway helper if the problem continues."
            )
        )
    }

    private static func registrationProbeTimeoutError() -> PrivilegedHelperError {
        let status = serviceStatus
        guard status == .enabled else { return statusError(status) }
        return .helperReported(
            PrivilegedHelperErrorPayload(
                code: "gatewayHelperProbeTimeout",
                message: "Gateway helper was registered but did not become reachable.",
                recoverySuggestion: "Try enabling Gateway again after approving it in System Settings."
            )
        )
    }

    private static func operationTimeoutError(_ operation: String) -> PrivilegedHelperError {
        .helperReported(
            PrivilegedHelperErrorPayload(
                code: "gatewayTimeout",
                message: "Gateway \(operation) did not complete within 45 seconds.",
                recoverySuggestion: "Refresh Gateway status before retrying."
            )
        )
    }

    private static var serviceStatus: SMAppService.Status {
        SMAppService.daemon(plistName: GatewayPrivilegedHelperConstants.launchDaemonPlistName).status
    }

    private static var unavailableError: PrivilegedHelperError {
        .helperReported(
            PrivilegedHelperErrorPayload(
                code: "gatewayHelperUnavailable",
                message: "Gateway helper is enabled but is not responding.",
                recoverySuggestion: "Reinstall the Gateway helper and try again."
            )
        )
    }

    private static func statusError(_ status: SMAppService.Status) -> PrivilegedHelperError {
        switch status {
        case .notRegistered: .needsRegistration
        case .requiresApproval:
            .helperReported(
                PrivilegedHelperErrorPayload(
                    code: "helperRequiresApproval",
                    message: "Gateway helper is installed but macOS has not allowed it to run in the background.",
                    recoverySuggestion: "Allow the Gateway helper in System Settings > General > Login Items & Extensions."
                )
            )
        case .notFound:
            .helperReported(
                PrivilegedHelperErrorPayload(
                    code: "gatewayHelperNotFound",
                    message: "Gateway helper registration is not initialized for this app bundle."
                )
            )
        case .enabled: .unavailable
        @unknown default: .unavailable
        }
    }

    private func handleConnectionEvent(_ event: PrivilegedHelperConnectionEvent, connection: NSXPCConnection) {
        connectionLock.lock()
        if self.connection === connection { self.connection = nil }
        let continuations = Array(eventContinuations.values)
        connectionLock.unlock()
        continuations.forEach { $0.yield(event) }
    }

    private func removeEventContinuation(id: UUID) {
        connectionLock.lock()
        eventContinuations.removeValue(forKey: id)
        connectionLock.unlock()
    }
}

private final class GatewayHelperCallState: @unchecked Sendable {
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
        guard !didFinish else { lock.unlock(); return }
        didFinish = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pendingResult = result }
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()
        timeoutTask?.cancel()
        if let continuation { resume(continuation, with: result) }
    }

    private func resume(_ continuation: CheckedContinuation<String, Error>, with result: Result<String, Error>) {
        switch result {
        case let .success(value): continuation.resume(returning: value)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }
}
