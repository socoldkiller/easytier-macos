import SwiftUI

struct PublishedServiceTargetCell: View {
    let row: PublishedServiceTableRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.targetEndpointLabel)
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(row.targetDetailLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .workspaceDataGridTwoLineContent()
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var helpText: String {
        let proxyAddress = row.proxyIPv4 == "—" ? "Unavailable" : row.proxyIPv4
        return "Target: \(row.targetEndpointLabel)\nProxy IPv4: \(proxyAddress)\nProtocol: \(row.protocolLabel)"
    }

    private var accessibilityLabel: String {
        "Target \(row.targetEndpointLabel), proxy IPv4 \(row.proxyIPv4), protocol \(row.protocolLabel)"
    }
}
