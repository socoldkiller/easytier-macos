import AppKit
import SwiftUI

extension View {
    func hiddenScrollIndicators() -> some View {
        scrollIndicators(.hidden, axes: [.vertical, .horizontal])
            .background {
                ScrollIndicatorHidingBridge()
                    .frame(width: 0, height: 0)
            }
    }
}

private struct ScrollIndicatorHidingBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        hideScrollIndicators(near: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        hideScrollIndicators(near: nsView)
    }

    private func hideScrollIndicators(near view: NSView) {
        DispatchQueue.main.async {
            view.enclosingScrollView?.hideScrollIndicators()
            view.window?.contentView?.hideScrollIndicatorsRecursively()
        }
    }
}

private extension NSView {
    func hideScrollIndicatorsRecursively() {
        if let scrollView = self as? NSScrollView {
            scrollView.hideScrollIndicators()
        }

        for subview in subviews {
            subview.hideScrollIndicatorsRecursively()
        }
    }
}

private extension NSScrollView {
    func hideScrollIndicators() {
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        verticalScroller?.isHidden = true
        horizontalScroller?.isHidden = true
    }
}
