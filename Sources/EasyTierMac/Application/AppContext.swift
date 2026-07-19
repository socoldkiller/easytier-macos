import EasyTierShared
import Observation

@MainActor
@Observable
final class AppContext {
    let runtime: ApplicationRuntimeCoordinator
    let workspace: WorkspaceFeature
    let settings: SettingsFeature
    let softwareUpdate: SoftwareUpdateFeature
    let presentation: AppPresentation

    @ObservationIgnored private var hasStarted = false

    init(
        runtime: ApplicationRuntimeCoordinator,
        workspace: WorkspaceFeature,
        settings: SettingsFeature,
        softwareUpdate: SoftwareUpdateFeature,
        presentation: AppPresentation
    ) {
        self.runtime = runtime
        self.workspace = workspace
        self.settings = settings
        self.softwareUpdate = softwareUpdate
        self.presentation = presentation
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        await runtime.load()
        await prepareRuntimeService()
        softwareUpdate.controller.start()
    }

    func prepareRuntimeService() async {
        guard await workspace.store.prepareRuntimeServiceAfterLaunch() else { return }
        await restoreRuntimeAfterHelperPreparation()
    }

    func resumeRuntimeServiceIfApproved() async {
        guard await workspace.store.resumeRuntimeServiceIfApproved() else { return }
        await restoreRuntimeAfterHelperPreparation()
    }

    func prepareForAppQuit() async {
        await runtime.prepareForAppQuit()
    }

    private func restoreRuntimeAfterHelperPreparation() async {
        await workspace.store.retryStartAfterHelperApproval()
        await softwareUpdate.controller.restorePendingRuntimeIfNeeded()
        await runtime.startGatewayIfNeeded()
    }

    var menuBarConnectionState: ConnectionGlyphState {
        let store = workspace.store
        if store.lastError != nil || store.selectedRuntimeReadinessPhase == .failed {
            return .error
        }
        if store.isBusy || store.isQuitting {
            return .connecting
        }
        guard var instance = store.selectedRunningInstance else {
            return .idle
        }
        instance.detail = store.selectedRuntimeDetail
        return store.instanceIsFullyConnected(instance) ? .connected : .connecting
    }
}
