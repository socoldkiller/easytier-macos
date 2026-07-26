import SwiftUI

struct AccountAvatarView: View {
    let size: CGFloat
    let showsStatus: Bool
    let isConnected: Bool

    var body: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .accessibilityLabel("Account avatar")
            .overlay(alignment: .bottomTrailing) {
                if showsStatus {
                    Circle()
                        .fill(isConnected ? EasyTierColors.statusConnected : .secondary)
                        .frame(width: size * 0.28, height: size * 0.28)
                        .overlay {
                            Circle()
                                .stroke(.background, lineWidth: 2)
                        }
                        .accessibilityLabel(isConnected ? "Connected" : "Disconnected")
                }
            }
    }
}
