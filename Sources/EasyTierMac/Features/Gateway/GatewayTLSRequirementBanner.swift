import SwiftUI

struct GatewayTLSRequirementBanner: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("TLS Setup Required")
                    .bold()
                Text("Configure Let’s Encrypt before publishing services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Configure TLS…", systemImage: "gearshape", action: action)
                .controlSize(.small)
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: .rect(cornerRadius: 10))
    }
}
