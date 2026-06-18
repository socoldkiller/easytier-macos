import CEasyTierFFI
import EasyTierShared
import Foundation

public final class StaticEasyTierFFIClient: EasyTierCoreClient, @unchecked Sendable {
    public init() {}

    public func version() async throws -> String {
        "EasyTier FFI (static)"
    }

    public func validate(toml: String) async throws {
        try Self.validateDirect(toml: toml)
    }

    public func run(config: NetworkConfig) async throws {
        let toml = try NetworkConfigTOMLCodec.encode(config)
        try await validate(toml: toml)
        try run(toml: toml)
    }

    public func run(toml: String) throws {
        try ffiCall(run_network_instance, withCString: toml)
    }

    public func stop(instanceNames: [String]) async throws {
        try stopSync(instanceNames: instanceNames)
    }

    public func stopSync(instanceNames: [String]) throws {
        guard !instanceNames.isEmpty else { return }
        let stopped = Set(instanceNames)
        let retained = try collectNetworkInfoPayloadsSync()
            .map(\.key)
            .filter { !stopped.contains($0) }
        try retainSync(instanceNames: retained)
    }

    public func retain(instanceNames: [String]) async throws {
        try retainSync(instanceNames: instanceNames)
    }

    public func retainSync(instanceNames: [String]) throws {
        try withCStringArray(instanceNames) { names in
            let result = retain_network_instance(names.baseAddress, UInt(names.count))
            if result != 0 { throw lastError() }
        }
    }

    public func listInstances() async throws -> [NetworkInstance] {
        try listInstancesSync()
    }

    public func listInstancesSync() throws -> [NetworkInstance] {
        let pairs = try collectNetworkInfoPayloadsSync()
        return pairs.map { NetworkInstance(instance_id: $0.key, name: $0.key, running: true) }
    }

    public func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] {
        try collectNetworkInfosSync()
    }

    public func collectNetworkInfosSync() throws -> [String: NetworkInstanceRunningInfo] {
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

    public func collectNetworkInfoPayloadsSync() throws -> [(key: String, value: String)] {
        try readPairs(command: collect_network_infos)
    }

    public func callJSONRPC(service: String, method: String, domain: String?, payload: String) async throws -> String {
        throw EasyTierCoreError.operationFailed("JSON-RPC bridge is not available with EasyTier Core v2.6.4 FFI.")
    }

    public func startConfigServerClient(url: URL) async throws {
        throw EasyTierCoreError.operationFailed("Config-server client mode is not available with EasyTier Core v2.6.4 FFI.")
    }

    public func stopConfigServerClient() async throws {
        // EasyTier Core v2.6.4 FFI does not expose config-server client state.
    }

    public func isConfigServerClientConnected() async throws -> Bool {
        throw EasyTierCoreError.operationFailed("Config-server client mode is not available with EasyTier Core v2.6.4 FFI.")
    }

    public static func validateDirect(toml: String) throws {
        try StaticEasyTierFFIClient().ffiCall(parse_config, withCString: toml)
    }

    private func ffiCall(_ body: (UnsafePointer<CChar>?) -> CInt, withCString value: String) throws {
        let result = value.withCString { body($0) }
        if result != 0 { throw lastError() }
    }

    private func readPairs(command: (UnsafeMutablePointer<KeyValuePair>?, UInt) -> CInt) throws -> [(key: String, value: String)] {
        var capacity = 32
        while true {
            var pairs = Array(repeating: KeyValuePair(key: nil, value: nil), count: capacity)
            let count = pairs.withUnsafeMutableBufferPointer { buffer in
                command(buffer.baseAddress, UInt(capacity))
            }
            if count < 0 { throw lastError() }
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

    private func withCStringArray<T>(_ strings: [String], _ body: (UnsafeMutableBufferPointer<UnsafePointer<CChar>?>) throws -> T) throws -> T {
        let cStrings = strings.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var pointers = cStrings.map { UnsafePointer<CChar>($0) }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer)
        }
    }

    private func lastError() -> EasyTierCoreError {
        var pointer: UnsafePointer<CChar>?
        get_error_msg(&pointer)
        defer { free_string(pointer) }
        if let pointer {
            return .operationFailed(String(cString: pointer))
        }
        return .operationFailed("EasyTier FFI operation failed")
    }
}
