import SwiftUI

struct PublishedServiceIPv4Cell: View {
    let row: PublishedServiceTableRow

    var body: some View {
        if row.proxyIPv4 == "—" {
            Text(row.proxyIPv4)
                .foregroundStyle(.secondary)
        } else {
            CopyableIPv4AddressCell(ipv4Address: row.proxyIPv4)
        }
    }
}
