import SwiftUI

struct MenuBarListButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var title: String
    var shortcut: String?
    var isDisabled = false
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(primaryTextColor)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(.body)
                        .foregroundStyle(shortcutTextColor)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, MenuBarPalette.selectedRowContentHorizontalPadding)
            .padding(.vertical, MenuBarPalette.selectedRowContentVerticalPadding)
            .background(rowBackground, in: .rect(cornerRadius: MenuBarPalette.selectedRowCornerRadius))
            .padding(.horizontal, MenuBarPalette.selectedRowHorizontalInset)
            .padding(.vertical, MenuBarPalette.selectedRowVerticalInset)
        }
        .buttonStyle(QuietPressButtonStyle(pressedScale: 0.985, pressedOpacity: 0.82))
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isHovering)
    }

    private var primaryTextColor: Color {
        if isDisabled { return MenuBarPalette.mutedText }
        return isHovering ? MenuBarPalette.selectedRowText : MenuBarPalette.primaryText
    }

    private var shortcutTextColor: Color {
        if isDisabled { return MenuBarPalette.mutedText.opacity(0.7) }
        return isHovering ? MenuBarPalette.selectedRowText.opacity(0.72) : MenuBarPalette.mutedText
    }

    private var rowBackground: Color {
        if isDisabled { return .clear }
        return isHovering ? MenuBarPalette.selectedRow : .clear
    }
}
