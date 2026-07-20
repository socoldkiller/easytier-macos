import SwiftUI

struct PublishedServiceSSLCell: View {
    var provider: PublishedServiceSSLProvider

    var body: some View {
        Label {
            Text(provider.label)
                .lineLimit(1)
        } icon: {
            Image(systemName: provider.isSecure ? "lock.fill" : "lock.open")
                .foregroundStyle(provider.isSecure ? EasyTierColors.statusConnected : .secondary)
        }
        .help(provider.helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("SSL: \(provider.label), \(provider.connectionLabel)"))
    }
}
