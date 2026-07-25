import SwiftUI

struct SettingsMetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .font(.body.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        } label: {
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}
