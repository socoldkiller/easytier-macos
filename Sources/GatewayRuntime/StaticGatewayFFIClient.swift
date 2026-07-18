import CGatewayFFI
import EasyTierShared
import Foundation

package protocol GatewayFFIRuntimeClient: Sendable {
    func startSync(configuration: GatewayFFIConfiguration) throws
    func applySync(configuration: GatewayFFIConfiguration) throws
    func stopSync() throws
    func statusSync() throws -> GatewayStatus
    func requestRenewalSync(certificateID: String?) throws
}

package final class StaticGatewayFFIClient: GatewayFFIRuntimeClient, Sendable {
    package init() {}

    package func startSync(configuration: GatewayFFIConfiguration) throws {
        let configurationJSON = try encode(configuration)
        let secretsJSON = try encode(GatewaySecrets.empty)
        var error: UnsafePointer<CChar>?
        let result = configurationJSON.withCString { configurationPointer in
            secretsJSON.withCString { secretsPointer in
                gateway_start(configurationPointer, secretsPointer, &error)
            }
        }
        try Self.throwOnError(result, error: error)
    }

    package func applySync(configuration: GatewayFFIConfiguration) throws {
        let configurationJSON = try encode(configuration)
        var error: UnsafePointer<CChar>?
        let result = configurationJSON.withCString { configurationPointer in
            gateway_apply_config(configurationPointer, nil, &error)
        }
        try Self.throwOnError(result, error: error)
    }

    package func stopSync() throws {
        var error: UnsafePointer<CChar>?
        let result = gateway_stop(&error)
        try Self.throwOnError(result, error: error)
    }

    package func statusSync() throws -> GatewayStatus {
        var output: UnsafePointer<CChar>?
        var error: UnsafePointer<CChar>?
        let result = gateway_status(&output, &error)
        defer {
            if let output { free_string(output) }
        }
        try Self.throwOnError(result, error: error)
        guard let output else {
            throw EasyTierCoreError.invalidResponse("Gateway FFI returned a null status response.")
        }
        do {
            return try JSONDecoder().decode(GatewayStatus.self, from: Data(String(cString: output).utf8))
        } catch {
            throw EasyTierCoreError.invalidResponse(
                "Failed to decode Gateway status: \(error.localizedDescription)"
            )
        }
    }

    package func requestRenewalSync(certificateID: String?) throws {
        var error: UnsafePointer<CChar>?
        let result: CInt
        if let certificateID, !certificateID.isEmpty {
            result = certificateID.withCString { pointer in
                gateway_request_renewal(pointer, &error)
            }
        } else {
            result = gateway_request_renewal(nil, &error)
        }
        try Self.throwOnError(result, error: error)
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw EasyTierCoreError.invalidResponse("Failed to encode Gateway payload as UTF-8 JSON.")
        }
        return string
    }

    private static func throwOnError(_ result: CInt, error: UnsafePointer<CChar>?) throws {
        if result == 0 {
            if let error { free_string(error) }
            return
        }
        if let error {
            defer { free_string(error) }
            throw EasyTierCoreError.operationFailed(String(cString: error))
        }
        throw EasyTierCoreError.operationFailed("Gateway FFI operation failed.")
    }
}
