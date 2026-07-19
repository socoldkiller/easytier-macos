package protocol GatewayClient: Sendable {
    func start(configuration: GatewayConfiguration) async throws
    func apply(configuration: GatewayConfiguration) async throws
    func stop() async throws
    func status() async throws -> GatewayStatus
    func requestRenewal(certificateID: String?) async throws
    func setRetainsRuntimeAfterDisconnect(_ retainsRuntime: Bool) async throws
}
