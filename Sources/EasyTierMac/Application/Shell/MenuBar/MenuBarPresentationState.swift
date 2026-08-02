import Observation

@MainActor
@Observable
final class MenuBarPresentationState {
    var isNetworkMenuPresented = false
}

struct MenuBarNetworkMenuHoverState {
    enum Region {
        case trigger
        case popover
    }

    private var isTriggerHovered = false
    private var isPopoverHovered = false

    var shouldRemainPresented: Bool {
        isTriggerHovered || isPopoverHovered
    }

    mutating func setHovering(_ hovering: Bool, in region: Region) {
        switch region {
        case .trigger:
            isTriggerHovered = hovering
        case .popover:
            isPopoverHovered = hovering
        }
    }

    mutating func reset() {
        isTriggerHovered = false
        isPopoverHovered = false
    }
}
