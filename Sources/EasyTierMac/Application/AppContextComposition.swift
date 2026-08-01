import EasyTierShared
import Foundation

extension AppContext {
    static func live(userDefaults: UserDefaults = .standard) -> AppContext {
        let helperRegistration = HelperRegistrationService()
        let gatewayHelperRegistration = HelperRegistrationService(kind: .gateway)
        let authenticationPresentation = NetworkSecretAuthenticationPresentationCoordinator()
        let privilegedClient = PrivilegedEasyTierClient()
        let networkSecretStore = SystemNetworkSecretStore(
            authenticationActivityObserver: authenticationPresentation
        )
        let database = ApplicationDatabase(networkSecretStore: networkSecretStore)
        let store = EasyTierAppStore(
            runtimeClient: privilegedClient,
            helperRegistration: helperRegistration,
            database: database,
            networkSecretStore: networkSecretStore,
            peerSubscriptionDataLoader: URLSessionPeerSubscriptionDataLoader(
                session: URLSession(configuration: .default)
            )
        )
        let gatewayClient = PrivilegedGatewayClient()
        let gateway = GatewayRuntimeController(
            client: gatewayClient,
            configurationStore: GatewayDatabaseConfigurationStore(database: database),
            helperRegistration: gatewayHelperRegistration,
            connectionMonitor: gatewayClient
        )
        let runtime = ApplicationRuntimeCoordinator(store: store, gateway: gateway)
        let account = AccountSettingsModel(
            database: database,
            runtime: privilegedClient,
            userDefaults: userDefaults,
            configurationAuthorityDidChange: { authority in
                store.setConfigurationAuthority(authority)
            }
        )
        return make(
            runtime: runtime,
            account: account,
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
        let storage = EasyTierStorage.isolatedForTesting()
        let networkSecretStore = SystemNetworkSecretStore()
        let database = ApplicationDatabase(
            baseDirectory: storage.baseDirectory,
            gatewayFileURL: storage.baseDirectory.appending(path: "gateway/config.json"),
            networkSecretStore: networkSecretStore
        )
        let store = EasyTierAppStore(
            runtimeClient: client,
            helperRegistration: nil,
            storage: storage,
            database: database,
            networkSecretStore: networkSecretStore,
            peerSubscriptionDataLoader: URLSessionPeerSubscriptionDataLoader(
                session: URLSession(configuration: .ephemeral)
            )
        )
        let gateway = GatewayRuntimeController(
            client: DisabledGatewayClient(),
            configurationStore: GatewayDatabaseConfigurationStore(database: database),
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
        account: AccountSettingsModel? = nil,
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
            account: account,
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
