import CEasyTierFFI
import EasyTierShared
import Foundation

package final class StaticEasyTierFFIClient: EasyTierCoreClient, @unchecked Sendable {
    package init() {}

    package func validate(toml: String) async throws {
        try Self.validateDirect(toml: toml)
    }

    package func run(toml: String) async throws {
        try runSync(toml: toml)
    }

    package func runSync(toml: String) throws {
        var error: UnsafePointer<CChar>?
        let result = toml.withCString { cfg in run_network_instance(cfg, &error) }
        try Self.throwOnError(result, error: error)
    }

    package func stop(instanceNames: [String]) async throws {
        try stopSync(instanceNames: instanceNames)
    }

    package func stopSync(instanceNames: [String]) throws {
        guard !instanceNames.isEmpty else { return }
        try Self.withCStringBuffer(instanceNames) { names in
            var error: UnsafePointer<CChar>?
            let result = stop_network_instance(names.baseAddress, UInt(names.count), &error)
            try Self.throwOnError(result, error: error)
        }
    }

    package func retain(instanceNames: [String]) async throws {
        try retainSync(instanceNames: instanceNames)
    }

    package func retainSync(instanceNames: [String]) throws {
        try Self.withCStringBuffer(instanceNames) { names in
            var error: UnsafePointer<CChar>?
            let result = retain_network_instance(names.baseAddress, UInt(names.count), &error)
            try Self.throwOnError(result, error: error)
        }
    }

    package func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] {
        // The FFI call (`collect_network_infos` -> `RPC_RUNTIME.block_on`) and the
        // per-instance JSON decode are CPU/IO-bound and have no main-actor
        // dependencies (DashMap-backed manager, Sendable client). Move them off
        // the incumbent actor so they don't contend with scroll layout passes
        // during 1 Hz polling. Callers always hop to `@MainActor` after awaiting.
        try await Task.detached(priority: .userInitiated) { [self] in
            try self.collectNetworkInfosSync()
        }.value
    }

    package func collectNetworkInfosSync() throws -> [String: NetworkInstanceRunningInfo] {
        let pairs = try collectNetworkInfoPayloadsSync()
        var output: [String: NetworkInstanceRunningInfo] = [:]
        let decoder = JSONDecoder()
        for pair in pairs {
            guard let data = pair.value.data(using: .utf8) else { continue }
            do {
                output[pair.key] = try decoder.decode(NetworkInstanceRunningInfo.self, from: data)
            } catch {
                throw EasyTierCoreError.invalidResponse("failed to decode runtime info for \(pair.key): \(error.localizedDescription)")
            }
        }
        return output
    }

    package func collectNetworkInfoPayloadsSync() throws -> [(key: String, value: String)] {
        try readPairs(command: collect_network_infos)
    }

    package func configureRPCPortal(_ rpcPortal: String?, whitelist: [String]?) async throws {
        try configureRPCPortalSync(rpcPortal, whitelist: whitelist)
    }

    package func configureRPCPortalSync(_ rpcPortal: String?, whitelist: [String]? = nil) throws {
        var error: UnsafePointer<CChar>?
        let result: CInt
        if let rpcPortal {
            let whitelist = whitelist?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            result = rpcPortal.withCString { pointer in
                guard let whitelist, !whitelist.isEmpty else {
                    return configure_rpc_portal(1, pointer, nil, 0, &error)
                }
                return Self.withCStringBuffer(whitelist) { buffer in
                    configure_rpc_portal(1, pointer, buffer.baseAddress, UInt(buffer.count), &error)
                }
            }
        } else {
            result = configure_rpc_portal(0, nil, nil, 0, &error)
        }
        try Self.throwOnError(result, error: error)
    }

    private static func withCStringBuffer<Result>(
        _ strings: [String],
        _ body: (UnsafeMutableBufferPointer<UnsafePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        let cStrings = strings.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var pointers = cStrings.map { UnsafePointer<CChar>($0) }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer)
        }
    }

    private func connectRPCClientSync(clientID: String, url: URL) throws {
        var error: UnsafePointer<CChar>?
        let result = clientID.withCString { clientIDPointer in
            url.absoluteString.withCString { urlPointer in
                connect_rpc_client(clientIDPointer, urlPointer, &error)
            }
        }
        try Self.throwOnError(result, error: error)
    }

    package func callJSONRPC(
        clientID: String,
        url: URL,
        service: String,
        method: String,
        domain: String?,
        payload: String
    ) async throws -> String {
        try callJSONRPCSync(
            clientID: clientID,
            url: url,
            service: service,
            method: method,
            domain: domain,
            payload: payload
        )
    }

    package func callJSONRPCSync(
        clientID: String,
        url: URL,
        service: String,
        method: String,
        domain: String?,
        payload: String
    ) throws -> String {
        try connectRPCClientSync(clientID: clientID, url: url)
        return try callConnectedJSONRPC(
            clientID: clientID,
            service: service,
            method: method,
            domain: domain,
            payload: payload
        )
    }

    private func callConnectedJSONRPC(clientID: String, service: String, method: String, domain: String?, payload: String) throws -> String {
        var output: UnsafePointer<CChar>?
        var error: UnsafePointer<CChar>?
        let result = withCStringTuple(clientID, service, method, payload) { cClientID, cService, cMethod, cPayload in
            if let domain {
                return domain.withCString { cDomain in
                    call_json_rpc(cClientID, cService, cMethod, cDomain, cPayload, &output, &error)
                }
            } else {
                return call_json_rpc(cClientID, cService, cMethod, nil, cPayload, &output, &error)
            }
        }
        try Self.throwOnError(result, error: error)
        guard let output else {
            throw EasyTierCoreError.invalidResponse("JSON-RPC FFI returned a null response")
        }
        defer { free_string(output) }
        return String(cString: output)
    }

    private func withCStringTuple<Result>(_ a: String, _ b: String, _ c: String, _ d: String, body: (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) throws -> Result) rethrows -> Result {
        try a.withCString { ca in
            try b.withCString { cb in
                try c.withCString { cc in
                    try d.withCString { cd in
                        try body(ca, cb, cc, cd)
                    }
                }
            }
        }
    }

    package static func validateDirect(toml: String) throws {
        var error: UnsafePointer<CChar>?
        let result = toml.withCString { cfg in parse_config(cfg, &error) }
        try throwOnError(result, error: error)
    }

    /// Convert an FFI result + out-error pair into a thrown `EasyTierCoreError`.
    /// On success the error pointer is expected to be null and is left untouched.
    /// On failure the error pointer owns a `CString` that is released here.
    private static func throwOnError(_ result: CInt, error: UnsafePointer<CChar>?) throws {
        if result == 0 {
            if let error { free_string(error) }
            return
        }
        if let error {
            defer { free_string(error) }
            throw EasyTierCoreError.operationFailed(String(cString: error))
        }
        throw EasyTierCoreError.operationFailed("EasyTier FFI operation failed")
    }

    private func readPairs(command: (UnsafeMutablePointer<KeyValuePair>?, UInt, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> CInt) throws -> [(key: String, value: String)] {
        var capacity = 32
        while true {
            var pairs = Array(repeating: KeyValuePair(key: nil, value: nil), count: capacity)
            var error: UnsafePointer<CChar>?
            let count = pairs.withUnsafeMutableBufferPointer { buffer in
                command(buffer.baseAddress, UInt(capacity), &error)
            }
            if count < 0 {
                if let error {
                    defer { free_string(error) }
                    throw EasyTierCoreError.operationFailed(String(cString: error))
                }
                throw EasyTierCoreError.operationFailed("EasyTier FFI operation failed")
            }
            if count < capacity {
                let returnedPairs = Array(pairs.prefix(Int(count)))
                defer {
                    for pair in returnedPairs {
                        free_string(pair.key)
                        free_string(pair.value)
                    }
                }

                return try returnedPairs.enumerated().map { index, pair in
                    guard let keyPointer = pair.key else {
                        throw EasyTierCoreError.invalidResponse("runtime info pair #\(index + 1) has a null key")
                    }
                    guard let valuePointer = pair.value else {
                        throw EasyTierCoreError.invalidResponse("runtime info pair #\(index + 1) has a null value")
                    }
                    return (key: String(cString: keyPointer), value: String(cString: valuePointer))
                }
            }
            for pair in pairs {
                free_string(pair.key)
                free_string(pair.value)
            }
            capacity *= 2
        }
    }
}
