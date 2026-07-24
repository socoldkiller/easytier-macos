import CoreGraphics

enum TitlebarScrollEdgeEffectGeometry {
    static func frame(
        containerBounds: CGRect,
        contentLayoutRect: CGRect,
        isFlipped: Bool,
        safeAreaTopInset: CGFloat = 0,
        titlebarControlCenterInset: CGFloat = 0
    ) -> CGRect {
        let contentLayoutHeight: CGFloat

        if isFlipped {
            contentLayoutHeight = contentLayoutRect.minY - containerBounds.minY
        } else {
            contentLayoutHeight = containerBounds.maxY - contentLayoutRect.maxY
        }

        let height = min(
            containerBounds.height,
            max(
                0,
                contentLayoutHeight,
                safeAreaTopInset,
                titlebarControlCenterInset * 2
            )
        )
        let originY = isFlipped ? containerBounds.minY : containerBounds.maxY - height

        return CGRect(
            x: containerBounds.minX,
            y: originY,
            width: containerBounds.width,
            height: height
        )
    }
}
