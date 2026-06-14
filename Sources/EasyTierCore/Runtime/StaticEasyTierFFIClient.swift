import CEasyTierFFI
import Foundation

public final class StaticEasyTierFFIClient: EasyTierCoreClient, @unchecked Sendable {
    public init() {}

    public func version() async throws -> String {
        "EasyTier FFI (static)"
    }

    public func validate(toml: String) async throws {
        if ProcessInfo.processInfo.environment["EASYTIER_VALIDATE_IN_PROCESS"] == "1" {
            try Self.validateDirect(toml: toml)
            return
        }
        try await Self.validateWithHelper(toml: toml)
    }

    public func run(config: NetworkConfig) async throws {
        let toml = NetworkConfigTOMLCodec.encode(config)
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
        false
    }

    public static func validateDirect(toml: String) throws {
        try StaticEasyTierFFIClient().ffiCall(parse_config, withCString: toml)
    }

    private static func validateWithHelper(toml: String) async throws {
        guard let helperURL = validatorExecutableURL() else {
            throw EasyTierCoreError.operationFailed("EasyTierValidator helper is missing. Rebuild the app with scripts/package-app.sh.")
        }

        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = helperURL
            process.arguments = ["validate"]

            var environment = ProcessInfo.processInfo.environment
            environment["EASYTIER_VALIDATE_IN_PROCESS"] = "1"
            process.environment = environment

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            stdin.fileHandleForWriting.write(Data(toml.utf8))
            try? stdin.fileHandleForWriting.close()
            process.waitUntilExit()

            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let message = [error, output]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }

            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                if process.terminationReason == .uncaughtSignal {
                    throw EasyTierCoreError.operationFailed("EasyTier config validation crashed in helper process (signal \(process.terminationStatus)).")
                }
                throw EasyTierCoreError.operationFailed(message ?? "EasyTier config validation failed.")
            }
        }.value
    }

    private static func validatorExecutableURL() -> URL? {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        let helperURL = executableURL.deletingLastPathComponent().appendingPathComponent("EasyTierValidator")
        if FileManager.default.isExecutableFile(atPath: helperURL.path) {
            return helperURL
        }
        return nil
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
                return pairs.prefix(Int(count)).map { pair in
                    let key = pair.key.map(String.init(cString:)) ?? ""
                    let value = pair.value.map(String.init(cString:)) ?? ""
                    free_string(pair.key)
                    free_string(pair.value)
                    return (key: key, value: value)
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
