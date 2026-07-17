import EasyTierShared
import SwiftUI

struct MenuBarNetworkAvatar: View {
    var state: ConnectionGlyphState

    var body: some View {
        ZStack {
            Circle()
                .fill(avatarColor)
            ConnectionGlyph(state: state, size: 20)
                .opacity(0.78)
        }
        .frame(width: 36, height: 36)
    }

    private var avatarColor: Color {
        switch state {
        case .connected: Color.primary.opacity(0.16)
        case .connecting: Color.primary.opacity(0.13)
        case .error: Color.primary.opacity(0.12)
        case .idle: Color.primary.opacity(0.09)
        }
    }
}
