import EasyTierShared
import Foundation

extension AppContext {
    static func live(userDefaults: UserDefaults = .standard) -> AppContext {
        let helperRegistration = HelperRegistrationService()
        let privilegedClient = PrivilegedEasyTierClient()
        let store = EasyTierAppStore(
            privilegedClient: privilegedClient,
            inProcessClient: StaticEasyTierFFIClient(),
            helperRegistration: helperRegistration,
            networkSecretStore: SystemNetworkSecretStore(
                authenticationActivityObserver: authenticationPresentation
            ),
            peerSubscriptionDataLoader: URLSessionPeerSubscriptionDataLoader(
                session: URLSession(configuration: .default)
            )
        )
        let gatewayClient = PrivilegedGatewayClient(helper: privilegedClient)
        let gateway = GatewayRuntimeController(
            client: gatewayClient,
            configurationStore: GatewayConfigurationStore(),
            helperRegistration: helperRegistration,
            connectionMonitor: gatewayClient
        )
        let runtime = ApplicationRuntimeCoordinator(store: store, gateway: gateway)
        return make(
            runtime: runtime,
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
        let client = PreviewEasyTierCoreClient()
        let store = EasyTierAppStore(
            runtimeClient: client,
            helperRegistration: nil,
            storage: .isolatedForTesting(),
            peerSubscriptionDataLoader: URLSessionPeerSubscriptionDataLoader(
                session: URLSession(configuration: .ephemeral)
            )
        )
        let gatewayConfigurationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("easytier-gateway-preview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
        let gateway = GatewayRuntimeController(
            client: DisabledGatewayClient(),
            configurationStore: GatewayConfigurationStore(fileURL: gatewayConfigurationURL),
            helperRegistration: nil
        )
        let runtime = ApplicationRuntimeCoordinator(store: store, gateway: gateway)
        return make(
            runtime: runtime,
            userDefaults: userDefaults,
            loginItemService: InMemoryLoginItemService(),
            privilegedHelper: NoOpPrivilegedHelperLifecycle(),
            softwareUpdateClientFactory: { _ in DisabledSoftwareUpdateClient() },
            dockIconVisibility: NoOpDockIconVisibilityService()
        )
    }

    private static func make(
        runtime: ApplicationRuntimeCoordinator,
        userDefaults: UserDefaults,
        loginItemService: any LoginItemService,
        privilegedHelper: any PrivilegedHelperLifecycle,
        softwareUpdateClientFactory: @escaping SoftwareUpdateController.ClientFactory,
        dockIconVisibility: any DockIconVisibilityApplying
    ) -> AppContext {
        let store = runtime.store
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
            runtime: runtime,
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
            runtime: runtime,
            workspace: workspace,
            settings: settings,
            softwareUpdate: softwareUpdate,
            presentation: presentation
        )
    }
}
