import SwiftUI

struct PublishedServicePreview: View {
    let publicURL: String
    let target: String
    let copyAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Public URL")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(publicURL)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Copy URL", systemImage: "doc.on.doc", action: copyAction)
                    .controlSize(.small)
            }
            Text("Routes to \(target)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(.quaternary.opacity(0.22), in: .rect(cornerRadius: 10))
    }
}
