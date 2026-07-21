import SwiftUI

struct GatewayCertificateErrorBanner: View {
    let failures: [PublishedServiceCertificateFailure]

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading) {
                Text("Managed HTTPS is unavailable")
                    .bold()

                ForEach(failures) { failure in
                    VStack(alignment: .leading) {
                        Text(failure.hostname)
                            .bold()
                        Text(failure.message)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .font(.callout)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1))
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
