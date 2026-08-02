import AppKit
import EasyTierShared
import SwiftUI

@MainActor
struct MenuBarNetworkPopoverRootView: View {
    let appContext: AppContext
    let dismissAction: () -> Void
    let hoverDidChange: (Bool) -> Void
    let preferredSizeDidChange: (NSSize) -> Void

    var body: some View {
        MenuBarNetworkPopoverContent(
            dismissAction: dismissAction,
            hoverDidChange: hoverDidChange,
            preferredSizeDidChange: preferredSizeDidChange
        )
        .environment(appContext)
    }
}

private struct MenuBarNetworkPopoverContent: View {
    @Environment(AppContext.self) private var appContext
    @Environment(\.colorScheme) private var colorScheme

    let dismissAction: () -> Void
    let hoverDidChange: (Bool) -> Void
    let preferredSizeDidChange: (NSSize) -> Void

    private var store: EasyTierAppStore { appContext.workspace.store }
    private var networks: [NetworkPresentationItem] { NetworkPresentationResolver.items(for: store) }
    private var controlsAreDisabled: Bool {
        !store.persistenceIsReady || store.isBusy || store.isQuitting
    }
    private var preferredSize: NSSize {
        MenuBarPopoverLayout.networkSize(itemCount: networks.count)
    }

    var body: some View {
        MenuBarNetworkSubmenu(
            networks: networks,
            controlsAreDisabled: controlsAreDisabled,
            select: selectNetwork,
            toggleConnection: toggleNetworkConnection
        )
        .frame(width: preferredSize.width, height: preferredSize.height, alignment: .top)
        .foregroundStyle(MenuBarPalette.primaryText)
        .background(menuBackgroundTint)
        .onHover(perform: hoverDidChange)
        .onAppear(perform: reportPreferredSize)
        .onChange(of: networks.count) { _, count in
            if count == 0 {
                dismissAction()
            } else {
                reportPreferredSize()
            }
        }
    }

    private var menuBackgroundTint: Color {
        Color(nsColor: .windowBackgroundColor)
            .opacity(colorScheme == .dark ? 0.58 : 0.68)
    }

    private func reportPreferredSize() {
        preferredSizeDidChange(preferredSize)
    }

    private func selectNetwork(_ id: String) {
        dismissAction()
        Task { await store.selectConfig(id: id) }
    }

    private func toggleNetworkConnection(_ id: String) {
        Task { await store.toggleConfigConnection(id: id) }
    }
}

private struct MenuBarNetworkSubmenu: View {
    let networks: [NetworkPresentationItem]
    let controlsAreDisabled: Bool
    let select: (String) -> Void
    let toggleConnection: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Networks")
                    .font(.body.weight(.medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            MenuBarDivider()

            MenuBarNetworkList(
                networks: networks,
                controlsAreDisabled: controlsAreDisabled,
                select: select,
                toggleConnection: toggleConnection
            )
        }
    }
}
