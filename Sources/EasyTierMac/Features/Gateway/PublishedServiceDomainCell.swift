import SwiftUI

struct PublishedServiceDomainCell: View {
    var row: PublishedServiceTableRow
    var onOpen: (PublishedServiceTableRow) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            onOpen(row)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.publicHostname)
                    .font(.callout.monospaced())
                    .foregroundStyle(isHovered ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Text(row.targetDomain)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .onHover { isHovered = $0 }
        .help("Open \(row.publicURL?.absoluteString ?? row.publicHostname)\nTarget: \(row.targetDomain)")
        .accessibilityLabel(Text("Open \(row.publicHostname) in the browser"))
        .accessibilityHint(Text("Proxies to \(row.targetDomain)"))
    }
}
