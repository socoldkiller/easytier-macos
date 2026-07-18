import EasyTierRuntime
import EasyTierShared
import Foundation

final class PrivilegedService: NSObject, EasyTierPrivilegedServiceProtocol, @unchecked Sendable {
    private let client = StaticEasyTierFFIClient()
    private let magicDNSResolverConfigurator = MagicDNSSystemResolverConfigurator()

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
            try client.runSync(toml: configTOML)
            try magicDNSResolverConfigurator.apply(from: configTOML)
            reply("ok", nil)
        } catch {
            fputs("helper run error: \(error.localizedDescription)\n", stderr)
            replyFailure(error, code: "runFailed", reply: reply)
        }
    }

    func stop(instanceNames: [String], reply: @escaping (String?, String?) -> Void) {
        run(reply: reply) {
            try client.stopSync(instanceNames: instanceNames)
            try removeMagicDNSResolverFilesIfNoInstancesRemain()
        }
    }

    func retain(instanceNames: [String], reply: @escaping (String?, String?) -> Void) {
        run(reply: reply) {
            try client.retainSync(instanceNames: instanceNames)
            try removeMagicDNSResolverFilesIfNoInstancesRemain()
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

    func callJSONRPC(clientID: String, url: String, service: String, method: String, domain: String?, payload: String, reply: @escaping (String?, String?) -> Void) {
        do {
            guard let url = URL(string: url) else {
                throw EasyTierCoreError.operationFailed("Invalid EasyTier RPC URL.")
            }
            let response = try client.callJSONRPCSync(
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

    func shutdown(reply: @escaping (String?, String?) -> Void) {
        try? magicDNSResolverConfigurator.removeManagedResolverFiles()
        reply("ok", nil)
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            Foundation.exit(EXIT_SUCCESS)
        }
    }

    private func removeMagicDNSResolverFilesIfNoInstancesRemain() throws {
        if try client.collectNetworkInfoPayloadsSync().isEmpty {
            try magicDNSResolverConfigurator.removeManagedResolverFiles()
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
        case "collectNetworkInfosFailed":
            "The network may still be starting. Refresh again in a few seconds."
        case "configureRPCPortalFailed":
            "Check that the selected RPC listen port is free, then try saving the mode again."
        case "callJSONRPCFailed":
            "Check that the remote device has rpc_portal enabled and that the RPC URL uses a private EasyTier IP address."
        default:
            nil
        }
    }
}

final class HelperDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let service = PrivilegedService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            let requirement = try EasyTierXPCCodeSigningRequirements.requirement(
                forPeerIdentifier: EasyTierPrivilegedHelperConstants.appBundleIdentifier
            )
            connection.setCodeSigningRequirement(requirement)
        } catch {
            fputs(
                "helper rejected XPC connection from pid \(connection.processIdentifier), uid \(connection.effectiveUserIdentifier): \(error.localizedDescription)\n",
                stderr
            )
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: EasyTierPrivilegedServiceProtocol.self)
        connection.exportedObject = service
        connection.activate()
        return true
    }
}

let listener = NSXPCListener(machServiceName: EasyTierPrivilegedHelperConstants.machServiceName)
let delegate = HelperDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
