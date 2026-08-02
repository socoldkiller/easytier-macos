import SwiftUI

struct MenuBarCurrentNetworkRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let network: NetworkPresentationItem?
    let showsNetworkMenuDisclosure: Bool
    let isNetworkMenuPresented: Bool
    let controlsAreDisabled: Bool
    let open: () -> Void
    let presentNetworkMenu: () -> Void
    let hoverDidChange: (Bool) -> Void
    let toggleNetworkMenu: () -> Void
    let toggleConnection: () -> Void

    @State private var isOpenHovering = false
    @State private var isToggleHovering = false
    @State private var isDisclosureHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                HStack(spacing: 8) {
                    NetworkStatusGlyph(state: network?.connectionState ?? .idle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(network?.networkName ?? "No Network Selected")
                            .font(.body.weight(.medium))
                            .foregroundStyle(primaryTextColor)
                            .lineLimit(1)
                        Text(network?.statusText ?? "Choose a network in the main window")
                            .font(.callout)
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietPressButtonStyle(pressedScale: 0.985, pressedOpacity: 0.82))
            .frame(maxWidth: .infinity)
            .onHover { isOpenHovering = $0 }

            if let network {
                if network.canToggle {
                    MenuBarConnectionSwitch(
                        phase: network.readiness,
                        isDisabled: controlsAreDisabled,
                        toggleConnection: toggleConnection
                    )
                    .onHover { isToggleHovering = $0 }
                    .help(network.readiness == .stopped ? "Start this network" : "Stop this network")
                } else {
                    Text("Managed")
                        .font(.caption)
                        .foregroundStyle(secondaryTextColor)
                }
            }

            if showsNetworkMenuDisclosure {
                Button(action: toggleNetworkMenu) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 24, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(QuietPressButtonStyle(pressedScale: 0.9, pressedOpacity: 0.72))
                .disabled(network == nil)
                .onHover { isDisclosureHovering = $0 }
                .help(isNetworkMenuPresented ? "Hide network list" : "Show all networks")
                .accessibilityLabel(isNetworkMenuPresented ? "Hide network list" : "Show all networks")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(rowBackground, in: .rect(cornerRadius: MenuBarPalette.selectedRowCornerRadius))
        .padding(.horizontal, MenuBarPalette.selectedRowHorizontalInset)
        .padding(.vertical, MenuBarPalette.selectedRowVerticalInset)
        .onHover { hovering in
            hoverDidChange(hovering)
            if hovering { presentNetworkMenu() }
        }
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isRowActive)
    }

    private var isRowActive: Bool {
        isOpenHovering
            || isToggleHovering
            || isDisclosureHovering
            || (showsNetworkMenuDisclosure && isNetworkMenuPresented)
    }

    private var primaryTextColor: Color {
        isRowActive ? MenuBarPalette.selectedRowText : MenuBarPalette.primaryText
    }

    private var secondaryTextColor: Color {
        isRowActive ? MenuBarPalette.selectedRowText.opacity(0.82) : MenuBarPalette.secondaryText
    }

    private var rowBackground: Color {
        isRowActive ? MenuBarPalette.selectedRow : .clear
    }
}

struct MenuBarNetworkList: View {
    let networks: [NetworkPresentationItem]
    let controlsAreDisabled: Bool
    let select: (String) -> Void
    let toggleConnection: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(networks) { network in
                    MenuBarNetworkListRow(
                        network: network,
                        controlsAreDisabled: controlsAreDisabled,
                        select: { select(network.id) },
                        toggleConnection: { toggleConnection(network.id) }
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .scrollIndicators(networks.count > 5 ? .visible : .hidden)
        .frame(height: CGFloat(min(networks.count, 5)) * 42 + 8)
        .background(MenuBarPalette.rowHighlight)
    }
}

private struct MenuBarNetworkListRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let network: NetworkPresentationItem
    let controlsAreDisabled: Bool
    let select: () -> Void
    let toggleConnection: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) {
                HStack(spacing: 8) {
                    Image(systemName: network.isSelected ? "checkmark" : "")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12)
                    NetworkStatusGlyph(state: network.connectionState)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(network.networkName)
                            .lineLimit(1)
                        Text(network.hostname ?? network.statusText)
                            .font(.caption)
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietPressButtonStyle(pressedScale: 0.985, pressedOpacity: 0.82))
            .frame(maxWidth: .infinity)

            if network.canToggle {
                MenuBarConnectionSwitch(
                    phase: network.readiness,
                    isDisabled: controlsAreDisabled,
                    toggleConnection: toggleConnection
                )
                .help(network.readiness == .stopped ? "Start this network" : "Stop this network")
            } else {
                Text("Managed")
                    .font(.caption2)
                    .foregroundStyle(secondaryTextColor)
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .frame(height: 41)
        .padding(.horizontal, 6)
        .background(
            isHovering ? MenuBarPalette.selectedRow : .clear,
            in: .rect(cornerRadius: MenuBarPalette.selectedRowCornerRadius)
        )
        .foregroundStyle(isHovering ? MenuBarPalette.selectedRowText : MenuBarPalette.primaryText)
        .onHover { isHovering = $0 }
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isHovering)
    }

    private var secondaryTextColor: Color {
        isHovering ? MenuBarPalette.selectedRowText.opacity(0.82) : MenuBarPalette.secondaryText
    }
}
