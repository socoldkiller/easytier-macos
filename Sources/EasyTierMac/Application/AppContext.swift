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
        await softwareUpdate.controller.restorePendingRuntimeIfNeeded()
        await runtime.startGatewayIfNeeded()
        softwareUpdate.controller.start()
    }

    func prepareForAppQuit() async {
        await runtime.prepareForAppQuit()
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
