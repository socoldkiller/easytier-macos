import SwiftUI

struct MenuBarNetworkAvatar: View {
    var body: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
    }
}
