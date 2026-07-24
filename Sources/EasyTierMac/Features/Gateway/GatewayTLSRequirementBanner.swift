import SwiftUI

struct GatewayTLSRequirementBanner: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Certificate Email Required")
                    .bold()
                Text("Add a contact email to resume Automatic HTTPS for these published services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Add Email…", systemImage: "envelope", action: action)
                .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: .rect(cornerRadius: 8))
    }
}
