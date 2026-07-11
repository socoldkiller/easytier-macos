import EasyTierShared
import EasyTierRuntime
import AppKit
import ServiceManagement
import SwiftUI

@main
struct EasyTierApp: App {
    @NSApplicationDelegateAdaptor(EasyTierApplicationDelegate.self) private var appDelegate
    @State private var store = EasyTierAppStore(
        inProcessClient: StaticEasyTierFFIClient(),
        helperRegistration: HelperRegistrationService()
    )
    @State private var updater = SoftwareUpdateController()
    @State private var menuBarController = MenuBarStatusItemController()
    @State private var appearanceSettings = AppAppearanceSettings()

    init() {
        Self.runHelperCommandIfRequested()
    }

    var body: some Scene {
        Window("EasyTier", id: "main") {
            ContentView()
                .environment(store)
                .environment(updater)
                .environment(appearanceSettings)
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
                .easyTierWindowBackground(glassEffectsEnabled: appearanceSettings.glassEffectsEnabled)
                .hideScrollViewScrollers()
                .background(
                    MenuBarStatusItemBridge(
                        controller: menuBarController,
                        store: store,
                        updater: updater,
                        appearanceSettings: appearanceSettings,
                        connectionState: menuBarConnectionState,
                        configureWindow: { window in
                            configureMainWindow(window, glassEffectsEnabled: appearanceSettings.glassEffectsEnabled)
                        }
                    )
                    .frame(width: 0, height: 0)
                )
                .background(
                    WindowAccessor { window in
                        configureMainWindow(window, glassEffectsEnabled: appearanceSettings.glassEffectsEnabled)
                    }
                    .frame(width: 0, height: 0)
                )
                .frame(minWidth: 900, idealWidth: 1100, minHeight: 620, idealHeight: 720)
                .task {
                    EasyTierApplicationDelegate.installQuitPreparation {
                        await store.prepareForAppQuit()
                    }
                    await store.load()
                    updater.scheduleAutomaticCheckIfNeeded()
                }
        }
        .windowToolbarStyle(.unified)

        Window("EasyTier", id: "settings") {
            EasyTierSettingsSheet(initialTab: .general, mode: store.mode, magicDNSSettings: store.magicDNSSettings) { mode, magicDNSSettings in
                Task { await store.applyMode(mode, magicDNSSettings: magicDNSSettings) }
            }
            .environment(store)
            .environment(updater)
            .environment(appearanceSettings)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .easyTierWindowBackground(glassEffectsEnabled: appearanceSettings.glassEffectsEnabled)
            .hideScrollViewScrollers()
            .background(
                WindowAccessor { window in
                    configureMainWindow(window, glassEffectsEnabled: appearanceSettings.glassEffectsEnabled)
                }
                .frame(width: 0, height: 0)
            )
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

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updater.checkForUpdatesAndPresent()
                }
            }

            CommandGroup(replacing: .appTermination) {
                Button("Quit EasyTier") {
                    EasyTierApplicationDelegate.quitEasyTier()
                }
                .keyboardShortcut("q")
            }
        }
    }

    private var menuBarConnectionState: ConnectionGlyphState {
        if store.lastError != nil || store.selectedRuntimeReadinessPhase == .failed { return .error }
        if store.isBusy || store.isQuitting { return .connecting }
        guard var instance = store.selectedRunningInstance else { return .idle }
        instance.detail = store.selectedRuntimeDetail
        return store.instanceIsFullyConnected(instance) ? .connected : .connecting
    }

    private func configureMainWindow(_ window: NSWindow, glassEffectsEnabled: Bool) {
        let frame = window.frame
        let effectiveGlass = glassEffectsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }

        let targetOpacity = !effectiveGlass
        if window.isOpaque != targetOpacity {
            window.isOpaque = targetOpacity
        }

        let targetBackgroundColor: NSColor = effectiveGlass ? .clear : .windowBackgroundColor
        if window.backgroundColor != targetBackgroundColor {
            window.backgroundColor = targetBackgroundColor
        }

        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
    }

    private static func runHelperCommandIfRequested() {
        let arguments = CommandLine.arguments
        if arguments.contains("--ping-helper") {
            runAsyncHelperCommandAndExit {
                try await PrivilegedEasyTierClient().helperPingPayload()
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
                if arguments.contains("--unregister-helper") || arguments.contains("--register-helper") {
                    try? await service.unregister()
                }
                if arguments.contains("--unregister-helper"),
                   LegacyPrivilegedHelperService.isInstalled,
                   ProcessInfo.processInfo.environment["EASYTIER_SKIP_LEGACY_HELPER_UNINSTALL"] != "1" {
                    try LegacyPrivilegedHelperService.uninstallUsingAdministratorPrivileges()
                }
                let registration = HelperRegistrationService()
                if arguments.contains("--register-helper") {
                    try await registration.ensureRegistered()
                } else {
                    await registration.refresh()
                }
                return "helper status: \(Self.describe(registration.state))"
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
