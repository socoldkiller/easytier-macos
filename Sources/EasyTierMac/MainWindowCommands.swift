import EasyTierShared
import Foundation
import SwiftUI

struct MainWindowCommandActions {
    let newNetwork: () -> Void
    let save: () -> Void
    let importTOML: () -> Void
    let exportTOML: () -> Void
    let canExportTOML: Bool
}

private struct MainWindowCommandActionsKey: FocusedValueKey {
    typealias Value = MainWindowCommandActions
}

extension FocusedValues {
    var mainWindowCommandActions: MainWindowCommandActions? {
        get { self[MainWindowCommandActionsKey.self] }
        set { self[MainWindowCommandActionsKey.self] = newValue }
    }
}

struct EasyTierCommands: Commands {
    @FocusedValue(\.mainWindowCommandActions) private var mainWindowActions

    let store: EasyTierAppStore
    let updater: SoftwareUpdateController

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Network") {
                mainWindowActions?.newNetwork()
            }
            .keyboardShortcut("n")
            .disabled(mainWindowActions == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                mainWindowActions?.save()
            }
            .keyboardShortcut("s")
            .disabled(mainWindowActions == nil)
        }

        CommandGroup(replacing: .importExport) {
            Button("Import TOML...") {
                mainWindowActions?.importTOML()
            }
            .disabled(mainWindowActions == nil)

            Button("Export TOML...") {
                mainWindowActions?.exportTOML()
            }
            .disabled(mainWindowActions?.canExportTOML != true)
        }

        CommandGroup(replacing: .appInfo) {
            Button("About EasyTier") {
                store.isShowingAbout = true
            }
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates...") {
                updater.checkForUpdatesAndPresent()
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings...") {
                store.isShowingSettings = true
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .appTermination) {
            Button("Quit EasyTier") {
                EasyTierApplicationDelegate.quitEasyTier()
            }
            .keyboardShortcut("q")
        }

        CommandGroup(replacing: .help) {
            Button("Install on Linux") {
                store.isShowingLinuxInstallGuide = true
            }

            Link("Online Docs", destination: Self.onlineDocsURL)
            Link("Releases", destination: Self.releasesURL)
        }
    }

    private static let onlineDocsURL = URL(string: "https://easytier.cn")!
    private static let releasesURL = URL(string: "https://github.com/EasyTier/EasyTier/releases")!
}
