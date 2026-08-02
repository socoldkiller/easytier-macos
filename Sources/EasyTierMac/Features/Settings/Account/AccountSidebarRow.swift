import SwiftUI

struct AccountSidebarRow: View {
    let account: SettingsAccount
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                AccountAvatarView(size: 30, showsStatus: true, isConnected: account.isConnected)

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .font(.body)
                        .bold()
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(account.serverName)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background(rowBackground, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowBackground: Color {
        if isSelected {
            return .primary.opacity(0.14)
        }
        if isHovered {
            return .primary.opacity(0.07)
        }
        return .clear
    }
}
