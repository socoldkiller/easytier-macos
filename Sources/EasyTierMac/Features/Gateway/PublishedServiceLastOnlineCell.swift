import Foundation
import SwiftUI

struct PublishedServiceLastOnlineCell: View {
    var lastOnlineAt: Date?

    var body: some View {
        Group {
            if let lastOnlineAt {
                Text(lastOnlineAt, format: .relative(presentation: .named))
                    .lineLimit(1)
                .help(lastOnlineAt.formatted(date: .complete, time: .standard))
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .help("No online event has been recorded in this Gateway session.")
                    .accessibilityLabel(Text("Last online time not recorded"))
            }
        }
    }
}
