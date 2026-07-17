import SwiftUI

@MainActor
struct MenuBarRootView: View {
    let appContext: AppContext
    let openMainWindowAction: () -> Void
    let quitApplicationAction: () -> Void
    let dismissMenuBarAction: () -> Void

    var body: some View {
        MenuBarContent(
            openMainWindowAction: openMainWindowAction,
            quitApplicationAction: quitApplicationAction,
            dismissMenuBarAction: dismissMenuBarAction
        )
        .environment(appContext)
    }
}
