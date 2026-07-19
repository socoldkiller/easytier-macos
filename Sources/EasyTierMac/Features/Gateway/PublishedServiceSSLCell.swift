import SwiftUI

struct PublishedServiceSSLCell: View {
    var provider: PublishedServiceSSLProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(provider.label)
                .lineLimit(1)
            Text(provider.connectionLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(provider.helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("SSL: \(provider.label), \(provider.connectionLabel)"))
    }
}
