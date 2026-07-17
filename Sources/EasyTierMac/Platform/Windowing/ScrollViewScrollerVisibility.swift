import AppKit
import SwiftUI

extension View {
    func hideScrollViewScrollers(vertical: Bool = true, horizontal: Bool = true) -> some View {
        let axes = hiddenScrollIndicatorAxes(vertical: vertical, horizontal: horizontal)
        return scrollIndicators(.hidden, axes: axes)
            .background(ScrollViewScrollerHider(axes: axes))
    }
}

private func hiddenScrollIndicatorAxes(vertical: Bool, horizontal: Bool) -> Axis.Set {
    var axes: Axis.Set = []
    if vertical { axes.insert(.vertical) }
    if horizontal { axes.insert(.horizontal) }
    return axes
}

private struct ScrollViewScrollerHider: NSViewRepresentable {
    var axes: Axis.Set

    func makeNSView(context _: Context) -> ScrollerHidingView {
        ScrollerHidingView(axes: axes)
    }

    func updateNSView(_ nsView: ScrollerHidingView, context _: Context) {
        nsView.axes = axes
        nsView.scheduleApply()
    }
}

private final class ScrollerHidingView: NSView {
    var axes: Axis.Set {
        didSet { scheduleApply() }
    }

    private var applyIsScheduled = false

    init(axes: Axis.Set) {
        self.axes = axes
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleApply()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleApply()
    }

    override func layout() {
        super.layout()
        scheduleApply()
    }

    func scheduleApply() {
        guard !applyIsScheduled else { return }
        applyIsScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyIsScheduled = false
            self.hideScrollers()
        }
    }

    private func hideScrollers() {
        guard let root = window?.contentView ?? hierarchyRoot else { return }
        root.hideScrollers(axes: axes)
    }

    private var hierarchyRoot: NSView? {
        var view: NSView? = self
        while let superview = view?.superview {
            view = superview
        }
        return view
    }
}

private extension NSView {
    func hideScrollers(axes: Axis.Set) {
        if let scrollView = self as? NSScrollView {
            scrollView.applyHiddenScrollers(axes: axes)
        }

        for subview in subviews {
            subview.hideScrollers(axes: axes)
        }
    }
}

private extension NSScrollView {
    func applyHiddenScrollers(axes: Axis.Set) {
        autohidesScrollers = true

        if axes.contains(.vertical) {
            hasVerticalScroller = false
            verticalScroller?.isHidden = true
        }

        if axes.contains(.horizontal) {
            hasHorizontalScroller = false
            horizontalScroller?.isHidden = true
        }
    }
}
