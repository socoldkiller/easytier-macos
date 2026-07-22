import SwiftUI

extension View {
    @ViewBuilder
    func easyTierScrollEdgeEffect(for edges: Edge.Set = .all) -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.automatic, for: edges)
        } else {
            self
        }
    }

    @ViewBuilder
    func easyTierSafeAreaBar<Bar: View>(
        edge: VerticalEdge,
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Bar
    ) -> some View {
        if #available(macOS 26.0, *) {
            safeAreaBar(edge: edge, alignment: alignment, spacing: spacing) {
                content()
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
                .scrollEdgeEffectStyle(.automatic, for: edge.edgeSet)
        } else {
            safeAreaInset(edge: edge, alignment: alignment, spacing: spacing) {
                content()
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }
}

private extension VerticalEdge {
    var edgeSet: Edge.Set {
        switch self {
        case .top: .top
        case .bottom: .bottom
        }
    }
}
