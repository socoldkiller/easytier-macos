import EasyTierShared
import AppKit
import ServiceManagement
import SwiftUI

enum EasyTierWindowID {
    static let main = EasyTierWindowRole.main.rawValue
    static let settings = EasyTierWindowRole.settings.rawValue
}

@main
struct EasyTierApp: App {
    @NSApplicationDelegateAdaptor(EasyTierApplicationDelegate.self) private var appDelegate
    @State private var appContext: AppContext

    init() {
        Self.runHelperCommandIfRequested()
        _appContext = State(initialValue: .live())
    }

    var body: some Scene {
        Window("EasyTier", id: EasyTierWindowID.main) {
            MainWindowView()
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
                .easyTierScrollEdgeEffect()
                .easyTierWindowBackground(
                    glassEffectsEnabled: appearanceSettings.glassEffectsEnabled,
                    renderCoordinator: appContext.presentation.glassRenderCoordinator
                )
                .hideScrollViewScrollers()
                .background(
                    MenuBarStatusItemBridge(
                        appContext: appContext,
                        connectionState: appContext.menuBarConnectionState,
                        quitApplicationAction: appDelegate.quitEasyTier
                    )
                    .frame(width: 0, height: 0)
                )
                .background(
                    WindowAccessor(
                        role: .main,
                        glassEffectsEnabled: appearanceSettings.glassEffectsEnabled,
                        activityDidChange: { activity in
                            appContext.presentation.mainWindow.activity = activity
                            store.setRuntimePresentationActivity(activity)
                        }
                    )
                    .frame(width: 0, height: 0)
                )
                .frame(minWidth: 900, idealWidth: 1100, minHeight: 620, idealHeight: 720)
                .task {
                    appDelegate.installApplicationActivityHandlers(
                        didBecomeActive: store.handleApplicationDidBecomeActive,
                        didResignActive: store.handleApplicationDidResignActive,
                        didHide: store.handleApplicationDidHide
                    )
                    if NSApplication.shared.isActive {
                        store.handleApplicationDidBecomeActive()
                    }
                    appDelegate.installQuitPreparation {
                        await appContext.prepareForAppQuit()
                    }
                    await appContext.start()
                }
                .environment(appContext)
                .environment(\.windowPresentationActivity, appContext.presentation.mainWindow.activity)
        }
        .windowToolbarStyle(.unified)

        Window("EasyTier", id: EasyTierWindowID.settings) {
            EasyTierSettingsSheet(
                initialTab: appContext.settings.requestedTab,
                mode: store.mode,
                magicDNSSettings: store.magicDNSSettings
            ) { mode, magicDNSSettings in
                Task { await store.applyMode(mode, magicDNSSettings: magicDNSSettings) }
            }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .easyTierScrollEdgeEffect()
            .easyTierWindowBackground(
                glassEffectsEnabled: appearanceSettings.glassEffectsEnabled,
                renderCoordinator: appContext.presentation.glassRenderCoordinator
            )
            .hideScrollViewScrollers()
            .background(
                WindowAccessor(
                    role: .settings,
                    glassEffectsEnabled: appearanceSettings.glassEffectsEnabled
                )
                .frame(width: 0, height: 0)
            )
            .environment(appContext)
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentSize)

        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Network") { store.addConfig() }
                    .keyboardShortcut("n")
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") { store.save() }
                    .keyboardShortcut("s")
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings...") { store.isShowingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }

            SoftwareUpdateCommands(appContext: appContext)

            CommandGroup(replacing: .appTermination) {
                Button("Quit EasyTier") {
                    appDelegate.quitEasyTier()
                }
                .keyboardShortcut("q")
            }
        }

    }

    private var store: EasyTierAppStore { appContext.workspace.store }
    private var appearanceSettings: AppAppearanceSettings { appContext.settings.appearance }

    private static func runHelperCommandIfRequested() {
        let arguments = CommandLine.arguments
        if arguments.contains("--ping-helper") {
            runAsyncHelperCommandAndExit {
                try await PrivilegedEasyTierClient().helperPingPayload()
            }
        }

        if arguments.contains("--ping-gateway-helper") {
            runAsyncHelperCommandAndExit {
                try await PrivilegedGatewayClient().helperPingPayload()
            }
        }

        guard arguments.contains("--register-helper") || arguments.contains("--unregister-helper") || arguments.contains("--helper-status") else { return }

        if arguments.contains("--register-helper") || arguments.contains("--unregister-helper") || arguments.contains("--helper-status") {
            if arguments.contains("--register-helper"), let locationError = helperInstallLocationError() {
                fputs("helper command failed: \(locationError)\n", stderr)
                print("helper status: \(Self.currentHelperStatusDescription())")
                Foundation.exit(EXIT_FAILURE)
            }

            runAsyncHelperCommandAndExit { @MainActor in
                let service = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName)
                let gatewayService = SMAppService.daemon(plistName: GatewayPrivilegedHelperConstants.launchDaemonPlistName)
                if arguments.contains("--unregister-helper") || arguments.contains("--register-helper") {
                    try? await service.unregister()
                    try? await gatewayService.unregister()
                }
                if arguments.contains("--unregister-helper"),
                   LegacyPrivilegedHelperService.isInstalled,
                   ProcessInfo.processInfo.environment["EASYTIER_SKIP_LEGACY_HELPER_UNINSTALL"] != "1" {
                    try LegacyPrivilegedHelperService.uninstallUsingAdministratorPrivileges()
                }
                let registration = HelperRegistrationService()
                let gatewayRegistration = HelperRegistrationService(kind: .gateway)
                if arguments.contains("--register-helper") {
                    var failures: [String] = []
                    do {
                        try await registration.ensureRegistered()
                    } catch {
                        failures.append("EasyTier: \(error.localizedDescription)")
                    }
                    do {
                        try await gatewayRegistration.ensureRegistered()
                    } catch {
                        failures.append("Gateway: \(error.localizedDescription)")
                    }
                    if !failures.isEmpty {
                        throw NSError(
                            domain: "EasyTierHelperRegistration",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")]
                        )
                    }
                } else {
                    await registration.refresh()
                    await gatewayRegistration.refresh()
                }
                return "helper status: EasyTier=\(Self.describe(registration.state)) Gateway=\(Self.describe(gatewayRegistration.state))"
            }
        }
    }

    private static func helperInstallLocationError() -> String? {
        if ProcessInfo.processInfo.environment["EASYTIER_ALLOW_UNSTABLE_HELPER_INSTALL"] == "1" {
            return nil
        }

        let path = Bundle.main.bundleURL.standardizedFileURL.path
        guard path == "/Applications/EasyTier.app" else {
            return "Move EasyTier.app to /Applications/EasyTier.app before installing the privileged helper. Current app path: \(path)"
        }
        return nil
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }

    private static func describe(_ state: HelperRegistrationService.State) -> String {
        switch state {
        case .notRegistered: "notRegistered"
        case .registering: "registering"
        case .requiresApproval: "requiresApproval"
        case .enabled: "enabled"
        case .notFound: "notFound"
        case .error: "error"
        }
    }

    private static func currentHelperStatusDescription() -> String {
        if LegacyPrivilegedHelperService.shouldUseLegacyInstaller {
            return LegacyPrivilegedHelperService.isInstalled ? "enabled" : "notRegistered"
        }
        let service = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName)
        return describe(service.status)
    }

    private static func runAsyncHelperCommandAndExit(_ command: @escaping () async throws -> String) {
        Task {
            do {
                let payload = try await command()
                print(payload)
                Foundation.exit(EXIT_SUCCESS)
            } catch {
                fputs("helper command failed: \(error.localizedDescription)\n", stderr)
                Foundation.exit(EXIT_FAILURE)
            }
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 30))
        fputs("helper command timed out\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
}

@MainActor
private struct SoftwareUpdateCommands: Commands {
    var appContext: AppContext

    private var updater: SoftwareUpdateController {
        appContext.softwareUpdate.controller
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…", action: updater.checkForUpdates)
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
