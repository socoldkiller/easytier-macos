import AppKit
import SwiftUI

extension View {
    func hideScrollViewScrollers(vertical: Bool = true, horizontal: Bool = true) -> some View {
        background(ScrollViewScrollerVisibilityBridge(hidesVerticalScroller: vertical, hidesHorizontalScroller: horizontal))
    }

    func hideEnclosingScrollViewScrollers(vertical: Bool = true, horizontal: Bool = true) -> some View {
        hideScrollViewScrollers(vertical: vertical, horizontal: horizontal)
    }
}

private struct ScrollViewScrollerVisibilityBridge: NSViewRepresentable {
    var hidesVerticalScroller: Bool
    var hidesHorizontalScroller: Bool

    func makeNSView(context _: Context) -> ScrollViewScrollerVisibilityBridgeView {
        let view = ScrollViewScrollerVisibilityBridgeView()
        view.configure(hidesVerticalScroller: hidesVerticalScroller, hidesHorizontalScroller: hidesHorizontalScroller)
        return view
    }

    func updateNSView(_ nsView: ScrollViewScrollerVisibilityBridgeView, context _: Context) {
        nsView.configure(hidesVerticalScroller: hidesVerticalScroller, hidesHorizontalScroller: hidesHorizontalScroller)
    }
}

private final class ScrollViewScrollerVisibilityBridgeView: NSView {
    private var hidesVerticalScroller = true
    private var hidesHorizontalScroller = false

    func configure(hidesVerticalScroller: Bool, hidesHorizontalScroller: Bool) {
        self.hidesVerticalScroller = hidesVerticalScroller
        self.hidesHorizontalScroller = hidesHorizontalScroller
        applyToEnclosingScrollView()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyToRelevantScrollViews()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyToRelevantScrollViews()
    }

    override func layout() {
        super.layout()
        applyToRelevantScrollViews()
    }

    private func applyToEnclosingScrollView() {
        applyToRelevantScrollViews()
    }

    private func applyToRelevantScrollViews() {
        var seen = Set<ObjectIdentifier>()

        if let scrollView = enclosingScrollView {
            apply(to: scrollView, seen: &seen)
        }

        var current = superview
        while let view = current {
            if let scrollView = view as? NSScrollView {
                apply(to: scrollView, seen: &seen)
            }
            current = view.superview
        }

        if let superview {
            applyToScrollViews(in: superview, seen: &seen)
        }

        if let contentView = window?.contentView {
            applyToScrollViews(in: contentView, seen: &seen)
        }
    }

    private func applyToScrollViews(in view: NSView, seen: inout Set<ObjectIdentifier>) {
        if let scrollView = view as? NSScrollView {
            apply(to: scrollView, seen: &seen)
        }

        for subview in view.subviews {
            applyToScrollViews(in: subview, seen: &seen)
        }
    }

    private func apply(to scrollView: NSScrollView, seen: inout Set<ObjectIdentifier>) {
        let identifier = ObjectIdentifier(scrollView)
        guard !seen.contains(identifier) else { return }
        seen.insert(identifier)

        scrollView.autohidesScrollers = true
        if hidesVerticalScroller {
            scrollView.hasVerticalScroller = false
            scrollView.verticalScroller?.isHidden = true
        }
        if hidesHorizontalScroller {
            scrollView.hasHorizontalScroller = false
            scrollView.horizontalScroller?.isHidden = true
        }
    }
}
