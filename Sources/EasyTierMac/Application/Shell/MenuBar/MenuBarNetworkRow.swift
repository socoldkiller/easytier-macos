import EasyTierShared
import SwiftUI

struct MenuBarNetworkRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var name: String
    var subtitle: String
    var state: ConnectionGlyphState
    var canSwitch: Bool
    var open: () -> Void
    var previous: () -> Void
    var next: () -> Void

    @State private var isOpenHovering = false
    @State private var isPreviousHovering = false
    @State private var isNextHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 10) {
                    MenuBarNetworkAvatar(state: state)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(primaryTextColor)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)

                    if !canSwitch {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.medium))
                            .foregroundStyle(primaryTextColor)
                    }
                }
                .contentShape(Rectangle())
                .padding(.leading, 8)
                .padding(.trailing, canSwitch ? 0 : 8)
                .padding(.vertical, 6)
            }
            .buttonStyle(QuietPressButtonStyle(pressedScale: 0.985, pressedOpacity: 0.82))
            .frame(maxWidth: .infinity)
            .onHover { isOpenHovering = $0 }

            if canSwitch {
                HStack(spacing: 0) {
                    inlineChevronButton(
                        systemName: "chevron.left",
                        help: "Previous network",
                        isHovering: $isPreviousHovering,
                        action: previous
                    )
                    inlineChevronButton(
                        systemName: "chevron.right",
                        help: "Next network",
                        isHovering: $isNextHovering,
                        action: next
                    )
                }
                .padding(.trailing, 4)
            }
        }
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, MenuBarPalette.selectedRowHorizontalInset)
        .padding(.vertical, MenuBarPalette.selectedRowVerticalInset)
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isOpenHovering)
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isPreviousHovering)
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isNextHovering)
        .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: name)
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

    private var isRowActive: Bool {
        isOpenHovering || isPreviousHovering || isNextHovering
    }

    private func inlineChevronButton(
        systemName: String,
        help: String,
        isHovering: Binding<Bool>,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(inlineChevronColor(isHovering: isHovering.wrappedValue))
                .frame(width: 24, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietPressButtonStyle(pressedScale: 0.9, pressedOpacity: 0.76))
        .onHover { isHovering.wrappedValue = $0 }
        .help(help)
    }

    private func inlineChevronColor(isHovering: Bool) -> Color {
        isRowActive
            ? MenuBarPalette.selectedRowText.opacity(isHovering ? 1.0 : 0.92)
            : MenuBarPalette.primaryText
    }
}
