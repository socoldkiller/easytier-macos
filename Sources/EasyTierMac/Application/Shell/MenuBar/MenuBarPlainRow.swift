import SwiftUI

struct MenuBarPlainRow: View {
    var title: String
    var isMuted = false

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(isMuted ? MenuBarPalette.mutedText : MenuBarPalette.primaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
