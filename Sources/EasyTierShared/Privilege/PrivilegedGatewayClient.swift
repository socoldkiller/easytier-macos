import Foundation

package final class PrivilegedGatewayClient: GatewayClient, Sendable {
    private let helper: PrivilegedEasyTierClient

    package init(helper: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) {
        self.helper = helper
    }

    package func start(configuration: GatewayConfiguration) async throws {
        try await helper.gatewayStart(
            configurationJSON: try encodeValidated(configuration)
        )
    }

    package func apply(configuration: GatewayConfiguration) async throws {
        try await helper.gatewayApply(
            configurationJSON: try encodeValidated(configuration)
        )
    }

    package func stop() async throws {
        try await helper.gatewayStop()
    }

    package func status() async throws -> GatewayStatus {
        let payload = try await helper.gatewayStatusJSON()
        do {
            return try JSONDecoder().decode(GatewayStatus.self, from: Data(payload.utf8))
        } catch {
            throw PrivilegedHelperError.invalidPayload(
                "Failed to decode Gateway status: \(error.localizedDescription)"
            )
        }
    }

    package func requestRenewal(certificateID: String?) async throws {
        try await helper.gatewayRequestRenewal(certificateID: certificateID)
    }

    package func connectionEvents() -> AsyncStream<PrivilegedHelperConnectionEvent> {
        helper.connectionEvents()
    }

    package func probeHelperAvailability() async throws {
        try await helper.probeHelperAvailability()
    }

    private func encodeValidated(_ configuration: GatewayConfiguration) throws -> String {
        let normalized = try GatewayConfigurationValidator.validate(configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(normalized)
        guard let string = String(data: data, encoding: .utf8) else {
            throw PrivilegedHelperError.invalidPayload(
                "Failed to encode Gateway configuration as UTF-8 JSON."
            )
        }
        return string
    }
}
