import GatewayRuntime
import EasyTierShared
import Foundation

private final class GatewayReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didReply = false
    private let reply: (String?, String?) -> Void

    init(_ reply: @escaping (String?, String?) -> Void) {
        self.reply = reply
    }

    func call(_ payload: String?, _ error: String?) {
        lock.lock()
        guard !didReply else { lock.unlock(); return }
        didReply = true
        lock.unlock()
        reply(payload, error)
    }
}

private final class GatewayPrivilegedService: NSObject, GatewayPrivilegedServiceProtocol, @unchecked Sendable {
    private let controller: GatewayHelperController
    private let session: GatewayHelperSession

    init(controller: GatewayHelperController, session: GatewayHelperSession) {
        self.controller = controller
        self.session = session
    }

    func ping(reply: @escaping (String?, String?) -> Void) {
        reply(GatewayPrivilegedHelperConstants.pingPayload, nil)
    }

    func buildInfo(reply: @escaping (String?, String?) -> Void) {
        do {
            let data = try JSONEncoder().encode(GatewayHelperBuildInfo(bundle: .main))
            reply(String(decoding: data, as: UTF8.self), nil)
        } catch {
            replyFailure(error, code: "buildInfoFailed", reply: reply)
        }
    }

    func start(configurationJSON: String, reply: @escaping (String?, String?) -> Void) {
        run(code: "gatewayStartFailed", reply: reply) { [controller, session] in
            try await controller.start(configurationJSON: configurationJSON, session: session)
            return "ok"
        }
    }

    func apply(configurationJSON: String, reply: @escaping (String?, String?) -> Void) {
        run(code: "gatewayApplyFailed", reply: reply) { [controller, session] in
            try await controller.apply(configurationJSON: configurationJSON, session: session)
            return "ok"
        }
    }

    func stop(reply: @escaping (String?, String?) -> Void) {
        run(code: "gatewayStopFailed", reply: reply) { [controller, session] in
            try await controller.stop(session: session)
            return "ok"
        }
    }

    func status(reply: @escaping (String?, String?) -> Void) {
        run(code: "gatewayStatusFailed", reply: reply) { [controller, session] in
            try await controller.status(session: session)
        }
    }

    func requestRenewal(certificateID: String?, reply: @escaping (String?, String?) -> Void) {
        run(code: "gatewayRenewalFailed", reply: reply) { [controller, session] in
            try await controller.requestRenewal(certificateID: certificateID, session: session)
            return "ok"
        }
    }

    func shutdown(reply: @escaping (String?, String?) -> Void) {
        let replyBox = GatewayReplyBox(reply)
        Task { @concurrent [controller] in
            do {
                try await controller.shutdown()
                replyBox.call("ok", nil)
            } catch {
                replyBox.call(nil, Self.errorPayload(error, code: "gatewayShutdownFailed").encodedString())
            }
            try? await Task.sleep(for: .milliseconds(50))
            Foundation.exit(EXIT_SUCCESS)
        }
    }

    private func run(
        code: String,
        reply: @escaping (String?, String?) -> Void,
        operation: @escaping @Sendable () async throws -> String
    ) {
        let replyBox = GatewayReplyBox(reply)
        Task { @concurrent in
            do {
                replyBox.call(try await operation(), nil)
            } catch {
                fputs("gateway helper \(code) error: \(error.localizedDescription)\n", stderr)
                replyBox.call(nil, Self.errorPayload(error, code: code).encodedString())
            }
        }
    }

    private func replyFailure(_ error: Error, code: String, reply: @escaping (String?, String?) -> Void) {
        reply(nil, Self.errorPayload(error, code: code).encodedString())
    }

    private static func errorPayload(_ error: Error, code: String) -> PrivilegedHelperErrorPayload {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return PrivilegedHelperErrorPayload(
            code: code,
            message: message.isEmpty ? "Gateway privileged helper operation failed." : message,
            recoverySuggestion: recoverySuggestion(for: code)
        )
    }

    private static func recoverySuggestion(for code: String) -> String? {
        switch code {
        case "gatewayStartFailed", "gatewayApplyFailed":
            "Check that ports 80 and 443 are free and that the Gateway configuration is valid."
        case "gatewayStopFailed", "gatewayShutdownFailed":
            "Reinstall the Gateway helper if its privileged listeners remain active."
        case "gatewayRenewalFailed":
            "Refresh Gateway status and verify the certificate ID before retrying renewal."
        default:
            nil
        }
    }
}

private final class GatewayHelperDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let controller = GatewayHelperController(
        legacyStorageRoot: URL(
            fileURLWithPath: "/Library/Application Support/EasyTier/Gateway",
            isDirectory: true
        ),
        idleExitHandler: { Foundation.exit(EXIT_SUCCESS) }
    )

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let session = GatewayHelperSession(userID: connection.effectiveUserIdentifier)
        let service = GatewayPrivilegedService(controller: controller, session: session)
        connection.setCodeSigningRequirement(PrivilegedHelperClientRequirement.current)
        connection.exportedInterface = NSXPCInterface(with: GatewayPrivilegedServiceProtocol.self)
        connection.exportedObject = service
        connection.interruptionHandler = { [controller] in
            Task { @concurrent in await controller.sessionDidInvalidate(session) }
        }
        connection.invalidationHandler = { [controller] in
            Task { @concurrent in await controller.sessionDidInvalidate(session) }
        }
        connection.activate()
        return true
    }
}

private let listener = NSXPCListener(machServiceName: GatewayPrivilegedHelperConstants.machServiceName)
private let delegate = GatewayHelperDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
