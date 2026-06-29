import SwiftUI

struct EasyTierMark: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image("easytier-icon")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.12), radius: 10, x: 0, y: 5)
            .accessibilityLabel(Text("EasyTier app icon"))
    }
}