import SwiftUI

struct ListenerStatusText: View {
    let address: String?
    let inactiveDescription: String

    var body: some View {
        Text(address ?? inactiveDescription)
            .font(.callout.monospaced())
            .foregroundStyle(address == nil ? .secondary : .primary)
            .textSelection(.enabled)
    }
}
