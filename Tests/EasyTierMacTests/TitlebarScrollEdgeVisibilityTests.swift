import Testing
@testable import EasyTierMac

@Test func titlebarScrollEdgeAppearsOnlyAfterContentMovesPastItsTopInset() {
    #expect(!TitlebarScrollEdgeVisibilityResolver.isVisible(contentOffsetY: -8, topInset: 12))
    #expect(!TitlebarScrollEdgeVisibilityResolver.isVisible(contentOffsetY: 12, topInset: 12))
    #expect(!TitlebarScrollEdgeVisibilityResolver.isVisible(contentOffsetY: 13, topInset: 12))
    #expect(TitlebarScrollEdgeVisibilityResolver.isVisible(contentOffsetY: 13.01, topInset: 12))
}
