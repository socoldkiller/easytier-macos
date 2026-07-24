import CoreGraphics

enum TitlebarScrollEdgeVisibilityResolver {
    static let activationDistance: CGFloat = 1

    static func isVisible(contentOffsetY: CGFloat, topInset: CGFloat) -> Bool {
        contentOffsetY - topInset > activationDistance
    }
}
