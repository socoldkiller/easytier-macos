import SwiftUI

struct MenuBarCopyRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var title: String
    var isCopied: Bool
    var isDisabled: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 18, height: 18)
                    .opacity(isDisabled ? 0 : 1)
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, MenuBarPalette.selectedRowContentVerticalPadding)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, MenuBarPalette.selectedRowHorizontalInset)
            .padding(.vertical, MenuBarPalette.selectedRowVerticalInset)
        }
        .buttonStyle(QuietPressButtonStyle(pressedScale: 0.985, pressedOpacity: 0.82))
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isCopied)
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isHovering)
        .help("Copy IP address")
        .accessibilityHint(Text("Copies the device IP address to the clipboard"))
        .accessibilityValue(Text(isCopied ? "Copied" : ""))
    }

    private var titleColor: Color {
        if isHovering, !isDisabled { return MenuBarPalette.selectedRowText }
        return isDisabled ? MenuBarPalette.mutedText : MenuBarPalette.primaryText
    }

    private var iconColor: Color {
        if isHovering, !isDisabled {
            return MenuBarPalette.selectedRowText.opacity(isCopied ? 0.98 : 0.82)
        }
        return isCopied ? MenuBarPalette.connected : MenuBarPalette.secondaryText
    }

    private var rowBackground: Color {
        if isHovering, !isDisabled { return MenuBarPalette.selectedRow }
        if isCopied { return MenuBarPalette.connected.opacity(0.16) }
        return .clear
    }
}
