import AppKit
import SwiftUI

@MainActor
struct MenuBarRootView: View {
    let appContext: AppContext
    let presentationState: MenuBarPresentationState
    let openMainWindowAction: () -> Void
    let quitApplicationAction: () -> Void
    let dismissMenuBarAction: () -> Void
    let networkMenuAnchorAvailabilityDidChange: @MainActor @Sendable (NSView, Bool) -> Void
    let networkMenuPresentationDidChange: (Bool) -> Void
    let networkMenuTriggerHoverDidChange: (Bool) -> Void
    let preferredSizeDidChange: (CGSize) -> Void

    init(
        appContext: AppContext,
        presentationState: MenuBarPresentationState = MenuBarPresentationState(),
        openMainWindowAction: @escaping () -> Void,
        quitApplicationAction: @escaping () -> Void,
        dismissMenuBarAction: @escaping () -> Void,
        networkMenuAnchorAvailabilityDidChange: @escaping @MainActor @Sendable (NSView, Bool) -> Void = { _, _ in },
        networkMenuPresentationDidChange: @escaping (Bool) -> Void = { _ in },
        networkMenuTriggerHoverDidChange: @escaping (Bool) -> Void = { _ in },
        preferredSizeDidChange: @escaping (CGSize) -> Void = { _ in }
    ) {
        self.appContext = appContext
        self.presentationState = presentationState
        self.openMainWindowAction = openMainWindowAction
        self.quitApplicationAction = quitApplicationAction
        self.dismissMenuBarAction = dismissMenuBarAction
        self.networkMenuAnchorAvailabilityDidChange = networkMenuAnchorAvailabilityDidChange
        self.networkMenuPresentationDidChange = networkMenuPresentationDidChange
        self.networkMenuTriggerHoverDidChange = networkMenuTriggerHoverDidChange
        self.preferredSizeDidChange = preferredSizeDidChange
    }

    var body: some View {
        MenuBarContent(
            openMainWindowAction: openMainWindowAction,
            quitApplicationAction: quitApplicationAction,
            dismissMenuBarAction: dismissMenuBarAction,
            presentationState: presentationState,
            networkMenuAnchorAvailabilityDidChange: networkMenuAnchorAvailabilityDidChange,
            networkMenuPresentationDidChange: networkMenuPresentationDidChange,
            networkMenuTriggerHoverDidChange: networkMenuTriggerHoverDidChange,
            preferredSizeDidChange: preferredSizeDidChange
        )
        .environment(appContext)
    }
}
