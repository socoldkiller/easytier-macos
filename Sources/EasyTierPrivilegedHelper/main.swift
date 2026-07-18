import EasyTierRuntime
import EasyTierShared
import Foundation

final class PrivilegedRuntime: @unchecked Sendable {
    let client = StaticEasyTierFFIClient()
    let magicDNSResolverConfigurator = MagicDNSSystemResolverConfigurator()
    let gateway: GatewayHelperController

    init() {
        let client = self.client
        gateway = GatewayHelperController(
            hasNetworkInstances: {
                guard let infos = try? client.collectNetworkInfoPayloadsSync() else {
                    return true
                }
                return !infos.isEmpty
            },
            idleExitHandler: {
                Foundation.exit(EXIT_SUCCESS)
            }
        )
    }
}

/// XPC reply blocks are invoked once, and the lock protects the only mutable field.
private final class XPCReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didReply = false
    private let reply: (String?, String?) -> Void

    init(_ reply: @escaping (String?, String?) -> Void) {
        self.reply = reply
    }

    func call(_ payload: String?, _ error: String?) {
        lock.lock()
        guard !didReply else {
            lock.unlock()
            return
        }
        didReply = true
        lock.unlock()
        reply(payload, error)
    }
}

final class PrivilegedService: NSObject, EasyTierPrivilegedServiceProtocol, @unchecked Sendable {
    private let runtime: PrivilegedRuntime
    private let session: GatewayHelperSession

    init(runtime: PrivilegedRuntime, session: GatewayHelperSession) {
        self.runtime = runtime
        self.session = session
    }

    func ping(reply: @escaping (String?, String?) -> Void) {
        reply(EasyTierPrivilegedHelperConstants.pingPayload, nil)
    }

    func validate(toml: String, reply: @escaping (String?, String?) -> Void) {
        do {
            try StaticEasyTierFFIClient.validateDirect(toml: toml)
            reply("ok", nil)
        } catch {
            replyFailure(error, code: "validationFailed", reply: reply)
        }
    }

    func run(configTOML: String, reply: @escaping (String?, String?) -> Void) {
        do {
            try runtime.client.runSync(toml: configTOML)
            try runtime.magicDNSResolverConfigurator.apply(from: configTOML)
            reply("ok", nil)
        } catch {
            fputs("helper run error: \(error.localizedDescription)\n", stderr)
            replyFailure(error, code: "runFailed", reply: reply)
        }
    }

    func stop(instanceNames: [String], reply: @escaping (String?, String?) -> Void) {
        run(reply: reply) {
            try runtime.client.stopSync(instanceNames: instanceNames)
            try removeMagicDNSResolverFilesIfNoInstancesRemain()
        }
    }

    func retain(instanceNames: [String], reply: @escaping (String?, String?) -> Void) {
        run(reply: reply) {
            try runtime.client.retainSync(instanceNames: instanceNames)
            try removeMagicDNSResolverFilesIfNoInstancesRemain()
        }
    }

    func collectNetworkInfos(reply: @escaping (String?, String?) -> Void) {
        do {
            let infos = try runtime.client.collectNetworkInfoPayloadsSync()
            let json = try buildCollectNetworkInfoJSON(from: infos)
            reply(json, nil)
        } catch {
            fputs("helper collectNetworkInfos error: \(error.localizedDescription)\n", stderr)
            replyFailure(error, code: "collectNetworkInfosFailed", reply: reply)
        }
    }

    func configureRPCPortal(
        rpcPortal: String?,
        whitelist: [String]?,
        reply: @escaping (String?, String?) -> Void
    ) {
        do {
            try runtime.client.configureRPCPortalSync(rpcPortal, whitelist: whitelist)
            reply("ok", nil)
        } catch {
            replyFailure(error, code: "configureRPCPortalFailed", reply: reply)
        }
    }

    func callJSONRPC(
        clientID: String,
        url: String,
        service: String,
        method: String,
        domain: String?,
        payload: String,
        reply: @escaping (String?, String?) -> Void
    ) {
        do {
            guard let url = URL(string: url) else {
                throw EasyTierCoreError.operationFailed("Invalid EasyTier RPC URL.")
            }
            let response = try runtime.client.callJSONRPCSync(
                clientID: clientID,
                url: url,
                service: service,
                method: method,
                domain: domain,
                payload: payload
            )
            reply(response, nil)
        } catch {
            replyFailure(error, code: "callJSONRPCFailed", reply: reply)
        }
    }

    func gatewayStart(configurationJSON: String, reply: @escaping (String?, String?) -> Void) {
        runGateway(code: "gatewayStartFailed", reply: reply) { [runtime, session] in
            try await runtime.gateway.start(configurationJSON: configurationJSON, session: session)
            return "ok"
        }
    }

    func gatewayApply(configurationJSON: String, reply: @escaping (String?, String?) -> Void) {
        runGateway(code: "gatewayApplyFailed", reply: reply) { [runtime, session] in
            try await runtime.gateway.apply(configurationJSON: configurationJSON, session: session)
            return "ok"
        }
    }

    func gatewayStop(reply: @escaping (String?, String?) -> Void) {
        runGateway(code: "gatewayStopFailed", reply: reply) { [runtime, session] in
            try await runtime.gateway.stop(session: session)
            return "ok"
        }
    }

    func gatewayStatus(reply: @escaping (String?, String?) -> Void) {
        runGateway(code: "gatewayStatusFailed", reply: reply) { [runtime, session] in
            try await runtime.gateway.status(session: session)
        }
    }

    func gatewayRequestRenewal(
        certificateID: String?,
        reply: @escaping (String?, String?) -> Void
    ) {
        runGateway(code: "gatewayRenewalFailed", reply: reply) { [runtime, session] in
            try await runtime.gateway.requestRenewal(
                certificateID: certificateID,
                session: session
            )
            return "ok"
        }
    }

    func shutdown(reply: @escaping (String?, String?) -> Void) {
        let replyBox = XPCReplyBox(reply)
        let runtime = runtime
        Task { @concurrent in
            do {
                try await runtime.gateway.shutdown()
                try runtime.magicDNSResolverConfigurator.removeManagedResolverFiles()
                replyBox.call("ok", nil)
            } catch {
                let payload = Self.errorPayload(error, code: "shutdownCleanupFailed")
                fputs("helper shutdown cleanup error: \(error.localizedDescription)\n", stderr)
                replyBox.call(nil, payload.encodedString())
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                Foundation.exit(EXIT_SUCCESS)
            }
        }
    }

    private func runGateway(
        code: String,
        reply: @escaping (String?, String?) -> Void,
        operation: @escaping @Sendable () async throws -> String
    ) {
        let replyBox = XPCReplyBox(reply)
        Task { @concurrent in
            do {
                replyBox.call(try await operation(), nil)
            } catch {
                fputs("helper \(code) error: \(error.localizedDescription)\n", stderr)
                replyBox.call(nil, Self.errorPayload(error, code: code).encodedString())
            }
        }
    }

    private func buildCollectNetworkInfoJSON(from pairs: [(key: String, value: String)]) throws -> String {
        let encoder = JSONEncoder()
        let entries = try pairs.map { pair in
            let data = try encoder.encode(pair.key)
            guard let keyJSON = String(data: data, encoding: .utf8) else {
                throw NSError(
                    domain: "EasyTierPrivilegedHelper",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "failed to encode key as UTF-8 JSON: \(pair.key)",
                    ]
                )
            }
            return "\(keyJSON): \(pair.value)"
        }
        return "{\(entries.joined(separator: ","))}"
    }

    private func removeMagicDNSResolverFilesIfNoInstancesRemain() throws {
        if try runtime.client.collectNetworkInfoPayloadsSync().isEmpty {
            try runtime.magicDNSResolverConfigurator.removeManagedResolverFiles()
        }
    }

    private func run(reply: @escaping (String?, String?) -> Void, _ operation: () throws -> Void) {
        do {
            try operation()
            reply("ok", nil)
        } catch {
            replyFailure(error, code: "operationFailed", reply: reply)
        }
    }

    private func replyFailure(
        _ error: Error,
        code: String,
        reply: @escaping (String?, String?) -> Void
    ) {
        reply(nil, Self.errorPayload(error, code: code).encodedString())
    }

    private static func errorPayload(_ error: Error, code: String) -> PrivilegedHelperErrorPayload {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return PrivilegedHelperErrorPayload(
            code: code,
            message: message.isEmpty ? "EasyTier privileged helper operation failed." : message,
            recoverySuggestion: recoverySuggestion(for: code)
        )
    }

    private static func recoverySuggestion(for code: String) -> String? {
        switch code {
        case "validationFailed":
            "Review the network config fields and try validating again."
        case "runFailed":
            "Check helper permissions and the EasyTier runtime error, then try starting the network again."
        case "collectNetworkInfosFailed":
            "The network may still be starting. Refresh again in a few seconds."
        case "configureRPCPortalFailed":
            "Check that the selected RPC listen port is free, then try saving the mode again."
        case "callJSONRPCFailed":
            "Check that the remote device has rpc_portal enabled and that the RPC URL uses a private EasyTier IP address."
        case "gatewayStartFailed", "gatewayApplyFailed":
            "Check that ports 80 and 443 are free and that the Gateway configuration is valid."
        case "gatewayStopFailed", "shutdownCleanupFailed":
            "Quit EasyTier again; if the helper remains, reinstall it to release the privileged listeners."
        case "gatewayRenewalFailed":
            "Refresh Gateway status and verify the certificate ID before retrying renewal."
        default:
            nil
        }
    }
}

final class HelperDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let runtime = PrivilegedRuntime()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let session = GatewayHelperSession(userID: connection.effectiveUserIdentifier)
        let service = PrivilegedService(runtime: runtime, session: session)

        connection.setCodeSigningRequirement(PrivilegedHelperClientRequirement.current)
        connection.exportedInterface = NSXPCInterface(with: EasyTierPrivilegedServiceProtocol.self)
        connection.exportedObject = service
        connection.interruptionHandler = { [gateway = runtime.gateway] in
            Task { @concurrent in
                await gateway.sessionDidInvalidate(session)
            }
        }
        connection.invalidationHandler = { [gateway = runtime.gateway] in
            Task { @concurrent in
                await gateway.sessionDidInvalidate(session)
            }
        }
        connection.activate()
        return true
    }
}

let listener = NSXPCListener(machServiceName: EasyTierPrivilegedHelperConstants.machServiceName)
let delegate = HelperDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
