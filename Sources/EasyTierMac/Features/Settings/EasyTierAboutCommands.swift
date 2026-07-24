import SwiftUI

struct EasyTierAboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About EasyTier") {
                openWindow(id: EasyTierWindowID.about)
            }
        }
    }
}
