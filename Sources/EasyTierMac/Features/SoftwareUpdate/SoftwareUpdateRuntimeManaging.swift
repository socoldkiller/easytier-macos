import EasyTierShared

@MainActor
protocol SoftwareUpdateRuntimeManaging: AnyObject {
    func runningConfigIDsForSoftwareUpdate() -> [String]
    func prepareForSoftwareUpdate() async
    func restoreConfigsAfterSoftwareUpdate(configIDs: [String]) async
    func recordNotice(_ message: String)
}

extension EasyTierAppStore: SoftwareUpdateRuntimeManaging {}
