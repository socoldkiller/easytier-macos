import EasyTierRuntime
import EasyTierShared
import Foundation

extension AppContext {
    static func live(userDefaults: UserDefaults = .standard) -> AppContext {
        let helperRegistration = HelperRegistrationService()
        let authenticationPresentation = NetworkSecretAuthenticationPresentationCoordinator()
        let store = EasyTierAppStore(
            inProcessClient: StaticEasyTierFFIClient(),
            helperRegistration: helperRegistration,
            networkSecretStore: SystemNetworkSecretStore(
                authenticationActivityObserver: authenticationPresentation
            ),
            peerSubscriptionDataLoader: URLSessionPeerSubscriptionDataLoader(
                session: URLSession(configuration: .default)
            )
        )
        return make(
            store: store,
            userDefaults: userDefaults,
            loginItemService: SystemLoginItemService(),
            privilegedHelper: SystemPrivilegedHelperLifecycle(),
            softwareUpdateClientFactory: { delegate in
                SparkleSoftwareUpdateClient(delegate: delegate)
            },
            dockIconVisibility: SystemDockIconVisibilityService()
        )
    }

    static func preview() -> AppContext {
        let suiteName = "com.kkrainbow.easytier.preview.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName) ?? UserDefaults()
        let client = StaticEasyTierFFIClient()
        let store = EasyTierAppStore(
            privilegedClient: client,
            inProcessClient: client,
            helperRegistration: nil,
            storage: .isolatedForTesting(),
            peerSubscriptionDataLoader: URLSessionPeerSubscriptionDataLoader(
                session: URLSession(configuration: .ephemeral)
            )
        )
        return make(
            store: store,
            userDefaults: userDefaults,
            loginItemService: InMemoryLoginItemService(),
            privilegedHelper: NoOpPrivilegedHelperLifecycle(),
            softwareUpdateClientFactory: { _ in DisabledSoftwareUpdateClient() },
            dockIconVisibility: NoOpDockIconVisibilityService()
        )
    }

    private static func make(
        store: EasyTierAppStore,
        userDefaults: UserDefaults,
        loginItemService: any LoginItemService,
        privilegedHelper: any PrivilegedHelperLifecycle,
        softwareUpdateClientFactory: @escaping SoftwareUpdateController.ClientFactory,
        dockIconVisibility: any DockIconVisibilityApplying
    ) -> AppContext {
        let workspace = WorkspaceFeature(store: store)
        let settings = SettingsFeature(
            appearance: AppAppearanceSettings(
                userDefaults: userDefaults,
                dockIconVisibility: dockIconVisibility
            ),
            loginItem: LoginItemController(
                userDefaults: userDefaults,
                service: loginItemService
            ),
            userDefaults: userDefaults
        )
        let softwareUpdate = SoftwareUpdateFeature(
            runtime: store,
            privilegedHelper: privilegedHelper,
            userDefaults: userDefaults,
            clientFactory: softwareUpdateClientFactory
        )
        let presentation = AppPresentation(
            menuBarController: MenuBarStatusItemController(),
            glassRenderCoordinator: GlassRenderCoordinator(),
            mainWindow: WindowPresentationModel()
        )
        return AppContext(
            workspace: workspace,
            settings: settings,
            softwareUpdate: softwareUpdate,
            presentation: presentation
        )
    }
}
