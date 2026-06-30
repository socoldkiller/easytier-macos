import SwiftUI

enum EasyTierMotion {
    static func quick(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.06) : .easeOut(duration: 0.14)
    }

    static func selection(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.26, dampingFraction: 0.84, blendDuration: 0.02)
    }

    static func content(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.10) : .spring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.02)
    }

    static func offset(for edge: Edge, distance: CGFloat) -> CGSize {
        switch edge {
        case .top:
            CGSize(width: 0, height: -distance)
        case .leading:
            CGSize(width: -distance, height: 0)
        case .bottom:
            CGSize(width: 0, height: distance)
        case .trailing:
            CGSize(width: distance, height: 0)
        }
    }

    static func opposite(of edge: Edge) -> Edge {
        switch edge {
        case .top: .bottom
        case .leading: .trailing
        case .bottom: .top
        case .trailing: .leading
        }
    }
}

extension AnyTransition {
    static func easyTierSlideFade(edge: Edge, distance: CGFloat = 14, scale: CGFloat = 0.997) -> AnyTransition {
        .modifier(
            active: EasyTierTransitionModifier(offset: EasyTierMotion.offset(for: edge, distance: distance), opacity: 0, scale: scale),
            identity: EasyTierTransitionModifier(offset: .zero, opacity: 1, scale: 1)
        )
    }

    static var easyTierScaleFade: AnyTransition {
        .modifier(
            active: EasyTierTransitionModifier(offset: CGSize(width: 0, height: 6), opacity: 0, scale: 0.985),
            identity: EasyTierTransitionModifier(offset: .zero, opacity: 1, scale: 1)
        )
    }
}

private struct EasyTierTransitionModifier: ViewModifier {
    var offset: CGSize
    var opacity: Double
    var scale: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(offset)
            .opacity(opacity)
    }
}

struct MotionSwitch<ID: Hashable, Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var id: ID
    var insertionEdge: Edge
    var distance: CGFloat
    var fillsAvailableSpace: Bool
    var content: Content

    init(
        id: ID,
        insertionEdge: Edge = .trailing,
        distance: CGFloat = 14,
        fillsAvailableSpace: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self.insertionEdge = insertionEdge
        self.distance = distance
        self.fillsAvailableSpace = fillsAvailableSpace
        self.content = content()
    }

    var body: some View {
        let switcher = ZStack(alignment: .topLeading) {
            content
                .id(id)
                .transition(transition)
        }

        if fillsAvailableSpace {
            switcher
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: id)
        } else {
            switcher
                .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: id)
        }
    }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .easyTierSlideFade(edge: insertionEdge, distance: distance),
            removal: .easyTierSlideFade(
                edge: EasyTierMotion.opposite(of: insertionEdge),
                distance: max(distance * 0.55, 4),
                scale: 0.999
            )
        )
    }
}

struct QuietPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var pressedScale: CGFloat = 0.985
    var pressedOpacity: Double = 0.84

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

extension View {
    func presentedSurfaceMotion() -> some View {
        modifier(PresentedSurfaceMotionModifier())
    }

    func toolbarAutoHidden(_ hidden: Bool, reduceMotion: Bool) -> some View {
        opacity(hidden ? 0 : 1)
            .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: hidden)
    }
}

private struct PresentedSurfaceMotionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .opacity(isPresented ? 1 : 0)
            .scaleEffect(reduceMotion || isPresented ? 1 : 0.985)
            .offset(y: reduceMotion || isPresented ? 0 : 8)
            .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: isPresented)
            .onAppear {
                guard !isPresented else { return }
                withAnimation(EasyTierMotion.content(reduceMotion: reduceMotion)) {
                    isPresented = true
                }
            }
    }
}
