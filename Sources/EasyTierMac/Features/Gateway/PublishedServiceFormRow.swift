import SwiftUI

struct PublishedServiceFormRow<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .imageScale(.small)
                    .frame(width: 14)

                Text(title)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 112, height: 24, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
