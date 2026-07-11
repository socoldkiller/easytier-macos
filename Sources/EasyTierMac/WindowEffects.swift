import AppKit
import SwiftUI

extension View {
    @ViewBuilder
    func easyTierWindowBackground(glassEffectsEnabled: Bool) -> some View {
        if glassEffectsEnabled {
            containerBackground(for: .window) {
                FrostedGlass(
                    material: .underWindowBackground,
                    blendingMode: .behindWindow
                )
            }
        } else {
            containerBackground(Color(nsColor: .windowBackgroundColor), for: .window)
        }
    }

    func easyTierSidebarBackground(glassEffectsEnabled: Bool) -> some View {
        background {
            if glassEffectsEnabled {
                FrostedGlass(
                    material: .sidebar,
                    blendingMode: .behindWindow
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
            }
        }
    }

    func frostedGlassBackground<S: Shape>(in shape: S) -> some View {
        modifier(FrostedGlassBackground(shape: shape))
    }

    func liquidGlassMetricBackground<S: Shape>(in shape: S) -> some View {
        modifier(LiquidGlassMetricBackground(shape: shape))
    }
}

private struct FrostedGlassBackground<S: Shape>: ViewModifier {
    @Environment(AppAppearanceSettings.self) private var appearanceSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var shape: S

    private var glassEnabled: Bool {
        appearanceSettings.glassEffectsEnabled && !reduceTransparency
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if glassEnabled && !appearanceSettings.glassPanelBackgroundsEnabled {
            content
        } else {
            content.background {
                if glassEnabled {
                    FrostedGlass(blendingMode: .withinWindow)
                        .clipShape(shape)
                } else {
                    shape.fill(Color.primary.opacity(0.045))
                }
            }
        }
    }
}

private struct LiquidGlassMetricBackground<S: Shape>: ViewModifier {
    @Environment(AppAppearanceSettings.self) private var appearanceSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var shape: S

    private var glassEnabled: Bool {
        appearanceSettings.glassEffectsEnabled && !reduceTransparency
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(backgroundColor)
            }
            .overlay {
                shape.stroke(strokeColor, lineWidth: 0.5)
            }
    }

    private var backgroundColor: Color {
        if glassEnabled {
            return Color.primary.opacity(colorScheme == .dark ? 0.038 : 0.052)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.052 : 0.075)
    }

    private var strokeColor: Color {
        if glassEnabled {
            return Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.065)
        }
        return Color.primary.opacity(0.075)
    }
}

struct FrostedGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        view.material = reduceTransparency ? .windowBackground : material
        view.blendingMode = blendingMode
        view.state = state
        view.autoresizingMask = [.width, .height]
    }
}

struct GlassFieldStyle: TextFieldStyle {
    @Environment(\.accessibilityShowButtonShapes) private var showButtonShapes

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        .primary.opacity(showButtonShapes ? 0.35 : 0.1),
                        lineWidth: showButtonShapes ? 1 : 0.5
                    )
            }
    }
}

extension TextFieldStyle where Self == GlassFieldStyle {
    static var glassField: GlassFieldStyle { .init() }
}

struct WindowAccessor: NSViewRepresentable {
    var configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        view.configureAction = { [configure] window in configure(window) }
        return view
    }

    func updateNSView(_ view: WindowAccessorView, context: Context) {
        view.configureAction = { [configure] window in configure(window) }
        if let window = view.window {
            view.applyConfiguration(to: window)
        }
    }
}

final class WindowAccessorView: NSView {
    var configureAction: ((NSWindow) -> Void)?
    nonisolated(unsafe) private var didBecomeKeyObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        applyConfiguration(to: window)
        installKeyWindowObserver(for: window)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        removeKeyWindowObserver()
    }

    func applyConfiguration(to window: NSWindow) {
        configureAction?(window)
    }

    private func installKeyWindowObserver(for window: NSWindow) {
        removeKeyWindowObserver()
        didBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let window = self.window else { return }
                self.applyConfiguration(to: window)
            }
        }
    }

    private func removeKeyWindowObserver() {
        if let didBecomeKeyObserver {
            NotificationCenter.default.removeObserver(didBecomeKeyObserver)
            self.didBecomeKeyObserver = nil
        }
    }

    deinit {
        if let didBecomeKeyObserver {
            NotificationCenter.default.removeObserver(didBecomeKeyObserver)
        }
    }
}
