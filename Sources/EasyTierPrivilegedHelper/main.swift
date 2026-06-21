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
            replyFailure(error, code: "listInstancesFailed", reply: reply)
        }
    }

    func collectNetworkInfos(reply: @escaping (String?, String?) -> Void) {
        do {
            let infos = try client.collectNetworkInfoPayloadsSync()
            var object: [String: Any] = [:]
            for info in infos {
                object[info.key] = try JSONSerialization.jsonObject(with: Data(info.value.utf8))
            }
            let data = try JSONSerialization.data(withJSONObject: object)
            reply(String(decoding: data, as: UTF8.self), nil)
        } catch {
            replyFailure(error, code: "collectNetworkInfosFailed", reply: reply)
        }
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

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    private let service = PrivilegedService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: EasyTierPrivilegedServiceProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: EasyTierPrivilegedHelperConstants.machServiceName)
let delegate = HelperDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
