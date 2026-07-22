import AppKit
import SwiftUI

struct TitlebarScrollEdgeEffectBridge: NSViewRepresentable {
    var isVisible: Bool

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.setVisible(isVisible)
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.setVisible(isVisible)
    }

    static func dismantleNSView(_ view: HostView, coordinator: ()) {
        view.tearDown()
    }
}

extension TitlebarScrollEdgeEffectBridge {
    @MainActor
    final class HostView: NSView {
        private let surfaceView = PassThroughTitlebarSurfaceView()
        private var surfaceConstraints: [NSLayoutConstraint] = []
        private var heightConstraint: NSLayoutConstraint?
        private var isVisible = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            surfaceView.setVisible(false)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installEffectIfNeeded()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window {
                uninstallEffect()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        func setVisible(_ visible: Bool) {
            isVisible = visible
            installEffectIfNeeded()
            surfaceView.setVisible(visible)
        }

        func tearDown() {
            uninstallEffect()
        }

        private func installEffectIfNeeded() {
            guard
                let window,
                let contentView = window.contentView,
                let containerView = contentView.superview
            else { return }
            if surfaceView.superview !== containerView {
                uninstallEffect()
                containerView.addSubview(surfaceView, positioned: .above, relativeTo: contentView)
                surfaceView.translatesAutoresizingMaskIntoConstraints = false
                let heightConstraint = surfaceView.heightAnchor.constraint(equalToConstant: 0)
                surfaceConstraints = [
                    surfaceView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                    surfaceView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                    surfaceView.topAnchor.constraint(equalTo: containerView.topAnchor),
                    heightConstraint,
                ]
                NSLayoutConstraint.activate(surfaceConstraints)
                self.heightConstraint = heightConstraint
            }
            heightConstraint?.constant = TitlebarScrollEdgeEffectGeometry.frame(
                containerBounds: containerView.bounds,
                contentLayoutRect: containerView.convert(window.contentLayoutRect, from: nil),
                isFlipped: containerView.isFlipped,
                safeAreaTopInset: max(
                    contentView.safeAreaInsets.top,
                    containerView.safeAreaInsets.top
                ),
                titlebarControlCenterInset: titlebarControlCenterInset(
                    window: window,
                    containerView: containerView
                )
            ).height
            surfaceView.setVisible(isVisible)
        }

        private func titlebarControlCenterInset(window: NSWindow, containerView: NSView) -> CGFloat {
            guard let closeButton = window.standardWindowButton(.closeButton) else { return 0 }
            let buttonFrame = containerView.convert(closeButton.bounds, from: closeButton)
            if containerView.isFlipped {
                return buttonFrame.midY - containerView.bounds.minY
            }
            return containerView.bounds.maxY - buttonFrame.midY
        }

        private func uninstallEffect() {
            NSLayoutConstraint.deactivate(surfaceConstraints)
            surfaceConstraints = []
            heightConstraint = nil
            surfaceView.removeFromSuperview()
        }
    }

    private final class PassThroughTitlebarSurfaceView: NSVisualEffectView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            material = .underWindowBackground
            blendingMode = .withinWindow
            state = .followsWindowActiveState
            alphaValue = 0.10
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        func setVisible(_ visible: Bool) {
            isHidden = !visible
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
