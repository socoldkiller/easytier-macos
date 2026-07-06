import AppKit
import SwiftUI

enum EasyTierIconResource {
    static let image: NSImage? = {
        if let mainURL = Bundle.main.url(forResource: "easytier-icon", withExtension: "png"),
           let image = NSImage(contentsOf: mainURL)
        {
            return image
        }

        if let moduleURL = Bundle.module.url(forResource: "easytier-icon", withExtension: "png") {
            return NSImage(contentsOf: moduleURL)
        }

        return nil
    }()
}

struct EasyTierMark: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = EasyTierIconResource.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .shadow(color: Color.primary.opacity(colorScheme == .dark ? 0.24 : 0.12), radius: 10, x: 0, y: 5)
                .accessibilityLabel(Text("EasyTier app icon"))
        }
    }
}
