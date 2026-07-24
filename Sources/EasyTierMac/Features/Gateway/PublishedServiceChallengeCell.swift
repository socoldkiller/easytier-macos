import SwiftUI

struct PublishedServiceChallengeCell: View {
    let challenge: String

    var body: some View {
        Text(challenge)
            .lineLimit(1)
            .help("ACME challenge: \(challenge)")
            .accessibilityLabel(Text("Certificate challenge: \(challenge)"))
    }
}
