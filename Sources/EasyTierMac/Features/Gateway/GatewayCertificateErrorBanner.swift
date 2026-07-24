import SwiftUI

struct GatewayCertificateErrorBanner: View {
    let failures: [PublishedServiceCertificateFailure]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 28)
                .background(
                    .orange.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text("Automatic HTTPS needs attention")
                    .font(.callout.weight(.semibold))

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(failures.enumerated()), id: \.element.id) { index, failure in
                        if index > 0 {
                            Divider()
                                .padding(.vertical, 8)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(failure.hostname)
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)

                            Text(failure.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.orange.opacity(0.025))
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.orange.opacity(0.22), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
    }
}
