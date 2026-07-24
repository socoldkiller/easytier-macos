import CoreGraphics
import Testing
@testable import EasyTierMac

@Test func titlebarScrollEdgeFrameCoversTopOfFlippedContentView() {
    let frame = TitlebarScrollEdgeEffectGeometry.frame(
        containerBounds: CGRect(x: 0, y: 0, width: 900, height: 620),
        contentLayoutRect: CGRect(x: 0, y: 52, width: 900, height: 568),
        isFlipped: true
    )

    #expect(frame == CGRect(x: 0, y: 0, width: 900, height: 52))
}

@Test func titlebarScrollEdgeFrameCoversTopOfUnflippedContentView() {
    let frame = TitlebarScrollEdgeEffectGeometry.frame(
        containerBounds: CGRect(x: 0, y: 0, width: 900, height: 620),
        contentLayoutRect: CGRect(x: 0, y: 0, width: 900, height: 568),
        isFlipped: false
    )

    #expect(frame == CGRect(x: 0, y: 568, width: 900, height: 52))
}

@Test func titlebarScrollEdgeFrameUsesTheFullTopSafeArea() {
    let frame = TitlebarScrollEdgeEffectGeometry.frame(
        containerBounds: CGRect(x: 0, y: 0, width: 900, height: 620),
        contentLayoutRect: CGRect(x: 0, y: 25, width: 900, height: 595),
        isFlipped: true,
        safeAreaTopInset: 52
    )

    #expect(frame == CGRect(x: 0, y: 0, width: 900, height: 52))
}

@Test func titlebarScrollEdgeFrameCoversTheUnifiedToolbarControlBand() {
    let frame = TitlebarScrollEdgeEffectGeometry.frame(
        containerBounds: CGRect(x: 0, y: 0, width: 900, height: 620),
        contentLayoutRect: CGRect(x: 0, y: 25, width: 900, height: 595),
        isFlipped: true,
        safeAreaTopInset: 25,
        titlebarControlCenterInset: 26
    )

    #expect(frame == CGRect(x: 0, y: 0, width: 900, height: 52))
}
