import EasyTierShared

@MainActor
protocol SoftwareUpdateRuntimeManaging: AnyObject {
    func runningConfigIDsForSoftwareUpdate() -> [String]
    func gatewayDesiredEnabledForSoftwareUpdate() -> Bool
    func prepareForSoftwareUpdate() async
    func restoreConfigsAfterSoftwareUpdate(configIDs: [String]) async
    func restoreGatewayAfterSoftwareUpdate(desiredEnabled: Bool) async
    func recordNotice(_ message: String)
}

extension EasyTierAppStore: SoftwareUpdateRuntimeManaging {}

extension SoftwareUpdateRuntimeManaging {
    func gatewayDesiredEnabledForSoftwareUpdate() -> Bool { false }
    func restoreGatewayAfterSoftwareUpdate(desiredEnabled: Bool) async {}
}
