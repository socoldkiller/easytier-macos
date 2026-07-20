package protocol GatewayClient: Sendable {
    func start(configuration: GatewayConfiguration) async throws
    func apply(configuration: GatewayConfiguration) async throws
    func start(configuration: GatewayConfiguration, secrets: GatewaySecrets) async throws
    func apply(configuration: GatewayConfiguration, secrets: GatewaySecrets) async throws
    func stop() async throws
    func status() async throws -> GatewayStatus
    func requestRenewal(certificateID: String?) async throws
    func setRetainsRuntimeAfterDisconnect(_ retainsRuntime: Bool) async throws
}

package extension GatewayClient {
    func start(configuration: GatewayConfiguration, secrets: GatewaySecrets) async throws {
        _ = secrets
        try await start(configuration: configuration)
    }

    func apply(configuration: GatewayConfiguration, secrets: GatewaySecrets) async throws {
        _ = secrets
        try await apply(configuration: configuration)
    }
}
