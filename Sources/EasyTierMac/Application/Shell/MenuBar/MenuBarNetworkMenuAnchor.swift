import AppKit
import SwiftUI

struct MenuBarNetworkMenuAnchor: NSViewRepresentable {
    let availabilityDidChange: @MainActor @Sendable (NSView, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(availabilityDidChange: availabilityDidChange)
    }

    func makeNSView(context: Context) -> AnchorView {
        AnchorView(availabilityDidChange: context.coordinator.availabilityDidChange)
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {}

    static func dismantleNSView(_ nsView: AnchorView, coordinator: Coordinator) {
        coordinator.availabilityDidChange(nsView, false)
    }

    final class AnchorView: NSView {
        let availabilityDidChange: @MainActor @Sendable (NSView, Bool) -> Void

        init(availabilityDidChange: @escaping @MainActor @Sendable (NSView, Bool) -> Void) {
            self.availabilityDidChange = availabilityDidChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            availabilityDidChange(self, window != nil)
        }
    }

    final class Coordinator {
        let availabilityDidChange: @MainActor @Sendable (NSView, Bool) -> Void

        init(availabilityDidChange: @escaping @MainActor @Sendable (NSView, Bool) -> Void) {
            self.availabilityDidChange = availabilityDidChange
        }
    }
}
