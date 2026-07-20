import SwiftUI

struct PublishedServiceExpiresCell: View {
    let presentation: PublishedServiceCertificatePresentation

    var body: some View {
        Text(presentation.label)
            .foregroundStyle(foregroundStyle)
            .lineLimit(1)
            .help(presentation.helpText)
            .accessibilityLabel(Text("Certificate expiration: \(presentation.label)"))
    }

    private var foregroundStyle: Color {
        switch presentation.tone {
        case .neutral: .secondary
        case .positive: .primary
        case .warning: .orange
        }
    }
}
