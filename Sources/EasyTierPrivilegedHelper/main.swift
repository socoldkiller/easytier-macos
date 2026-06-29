import EasyTierRuntime
import EasyTierShared
import Foundation

final class PrivilegedService: NSObject, EasyTierPrivilegedServiceProtocol, @unchecked Sendable {
    private let client = StaticEasyTierFFIClient()
    private let encoder = JSONEncoder()

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
            try StaticEasyTierFFIClient.validateDirect(toml: configTOML)
            try client.run(toml: configTOML)
            reply("ok", nil)
        } catch {
            fputs("helper run error: \(error.localizedDescription)\n", stderr)
            replyFailure(error, code: "runFailed", reply: reply)
        }
    }

    func stop(instanceNames: [String], reply: @escaping (String?, String?) -> Void) {
        run(reply: reply) { try client.stopSync(instanceNames: instanceNames) }
    }

    func retain(instanceNames: [String], reply: @escaping (String?, String?) -> Void) {
        run(reply: reply) { try client.retainSync(instanceNames: instanceNames) }
    }

    func listInstances(reply: @escaping (String?, String?) -> Void) {
        do {
            let instances = try client.listInstancesSync()
            reply(String(decoding: try encoder.encode(instances), as: UTF8.self), nil)
        } catch {
            fputs("helper listInstances error: \(error.localizedDescription)\n", stderr)
            replyFailure(error, code: "listInstancesFailed", reply: reply)
        }
    }

    func collectNetworkInfos(reply: @escaping (String?, String?) -> Void) {
        do {
            let infos = try client.collectNetworkInfoPayloadsSync()
            let json = try buildCollectNetworkInfoJSON(from: infos)
            reply(json, nil)
        } catch {
            fputs("helper collectNetworkInfos error: \(error.localizedDescription)\n", stderr)
            replyFailure(error, code: "collectNetworkInfosFailed", reply: reply)
        }
    }

    private func buildCollectNetworkInfoJSON(from pairs: [(key: String, value: String)]) throws -> String {
        let encoder = JSONEncoder()
        let entries = try pairs.map { pair in
            let data = try encoder.encode(pair.key)
            guard let keyJSON = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "EasyTierPrivilegedHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to encode key as UTF-8 JSON: \(pair.key)"])
            }
            return "\(keyJSON): \(pair.value)"
        }
        return "{\(entries.joined(separator: ","))}"
    }

    func configureRPCPortal(rpcPortal: String?, whitelist: [String]?, reply: @escaping (String?, String?) -> Void) {
        do {
            try client.configureRPCPortalSync(rpcPortal, whitelist: whitelist)
            reply("ok", nil)
        } catch {
            replyFailure(error, code: "configureRPCPortalFailed", reply: reply)
        }
    }

    func connectRPCClient(clientID: String, url: String, reply: @escaping (String?, String?) -> Void) {
        do {
            guard let url = URL(string: url) else {
                throw EasyTierCoreError.operationFailed("Invalid EasyTier RPC URL.")
            }
            try client.connectRPCClientSync(clientID: clientID, url: url)
            reply("ok", nil)
        } catch {
            replyFailure(error, code: "connectRPCClientFailed", reply: reply)
        }
    }

    func disconnectRPCClient(clientID: String, reply: @escaping (String?, String?) -> Void) {
        do {
            try client.disconnectRPCClientSync(clientID: clientID)
            reply("ok", nil)
        } catch {
            replyFailure(error, code: "disconnectRPCClientFailed", reply: reply)
        }
    }

    func callJSONRPC(clientID: String, service: String, method: String, domain: String?, payload: String, reply: @escaping (String?, String?) -> Void) {
        do {
            let response = try client.callJSONRPC(clientID: clientID, service: service, method: method, domain: domain, payload: payload)
            reply(response, nil)
        } catch {
            replyFailure(error, code: "callJSONRPCFailed", reply: reply)
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

    private func replyFailure(_ error: Error, code: String, reply: @escaping (String?, String?) -> Void) {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = PrivilegedHelperErrorPayload(
            code: code,
            message: message.isEmpty ? "EasyTier privileged helper operation failed." : message,
            recoverySuggestion: recoverySuggestion(for: code)
        )
        reply(nil, payload.encodedString())
    }

    private func recoverySuggestion(for code: String) -> String? {
        switch code {
        case "validationFailed":
            "Review the network config fields and try validating again."
        case "runFailed":
            "Check helper permissions and the EasyTier runtime error, then try starting the network again."
        case "collectNetworkInfosFailed", "listInstancesFailed":
            "The network may still be starting. Refresh again in a few seconds."
        case "configureRPCPortalFailed":
            "Check that the selected RPC listen port is free, then try saving the mode again."
        case "connectRPCClientFailed", "callJSONRPCFailed":
            "Check that the remote device has rpc_portal enabled and that the RPC URL uses a private EasyTier IP address."
        default:
            nil
        }
    }
}

final class HelperDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let service = PrivilegedService()
    private var activeConnections: Set<ObjectIdentifier> = []
    private let idleTimer = DispatchSource.makeTimerSource(queue: .main)
    private let idleTimeout: DispatchTimeInterval = .seconds(5)
    private var didExit = false

    override init() {
        super.init()
        idleTimer.setEventHandler { [weak self] in self?.exitIdle() }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: EasyTierPrivilegedServiceProtocol.self)
        connection.exportedObject = service
        let token = ObjectIdentifier(connection)
        connection.invalidationHandler = {
            DispatchQueue.main.async {
                self.activeConnections.remove(token)
                if self.activeConnections.isEmpty { self.scheduleIdleExit() }
            }
        }
        activeConnections.insert(token)
        idleTimer.suspend()
        connection.resume()
        return true
    }

    private func scheduleIdleExit() {
        idleTimer.suspend()
        idleTimer.schedule(deadline: .now() + idleTimeout)
        idleTimer.resume()
    }

    private func exitIdle() {
        guard !didExit, activeConnections.isEmpty else { return }
        didExit = true
        Foundation.exit(EXIT_SUCCESS)
    }
}

let listener = NSXPCListener(machServiceName: EasyTierPrivilegedHelperConstants.machServiceName)
let delegate = HelperDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
