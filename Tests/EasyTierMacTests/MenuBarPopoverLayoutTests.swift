import Foundation
import Testing
@testable import EasyTierMac

@Test func presentingTheNetworkMenuDoesNotResizeThePrimaryPopover() {
    let collapsedSize = MenuBarPopoverLayout.primarySize(for: NSSize(width: 300, height: 340))
    let requestedExpandedSize = MenuBarPopoverLayout.primarySize(for: NSSize(width: 551, height: 340))

    #expect(collapsedSize.width == 300)
    #expect(requestedExpandedSize.width == collapsedSize.width)
}

@Test func networkPopoverShowsAtMostFiveRows() {
    #expect(MenuBarPopoverLayout.networkSize(itemCount: 2).height == 132)
    #expect(MenuBarPopoverLayout.networkSize(itemCount: 8).height == 258)
}

@Test func networkPopoverUsesASeparateTrailingAttachment() {
    let primarySize = MenuBarPopoverLayout.primarySize(for: NSSize(width: 300, height: 340))
    let networkSize = MenuBarPopoverLayout.networkSize(itemCount: 2)

    #expect(MenuBarPopoverLayout.networkPreferredEdge == .maxX)
    #expect(primarySize == NSSize(width: 300, height: 340))
    #expect(networkSize == NSSize(width: 320, height: 132))
}

@Test func networkMenuHoverStateClosesAfterLeavingTriggerAndPopover() {
    var state = MenuBarNetworkMenuHoverState()

    state.setHovering(true, in: .trigger)
    #expect(state.shouldRemainPresented)

    state.setHovering(false, in: .trigger)
    state.setHovering(true, in: .popover)
    #expect(state.shouldRemainPresented)

    state.setHovering(false, in: .popover)
    #expect(!state.shouldRemainPresented)
}
