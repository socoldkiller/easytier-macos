import EasyTierShared

@MainActor
final class ApplicationRuntimeCoordinator: SoftwareUpdateRuntimeManaging {
    let store: EasyTierAppStore
    let gateway: GatewayRuntimeController

    init(store: EasyTierAppStore, gateway: GatewayRuntimeController) {
        self.store = store
        self.gateway = gateway
    }

    func load() async {
        await store.load()
        await gateway.load()
        gateway.startConnectionRecovery()
    }

    func startGatewayIfNeeded() async {
        await gateway.reconcile()
    }

    func prepareForAppQuit() async {
        await gateway.stopForLifecycle()
        await store.prepareForAppQuit()
    }

    func runningConfigIDsForSoftwareUpdate() -> [String] {
        store.runningConfigIDsForSoftwareUpdate()
    }

    func gatewayDesiredEnabledForSoftwareUpdate() -> Bool {
        gateway.desiredEnabled
    }

    func prepareForSoftwareUpdate() async {
        await gateway.stopForLifecycle()
        await store.prepareForSoftwareUpdate()
    }

    func restoreConfigsAfterSoftwareUpdate(configIDs: [String]) async {
        await store.restoreConfigsAfterSoftwareUpdate(configIDs: configIDs)
    }

    func restoreGatewayAfterSoftwareUpdate(desiredEnabled: Bool) async {
        await gateway.resumeAfterLifecycle()
    }

    func recordNotice(_ message: String) {
        store.recordNotice(message)
    }
}
