import AppKit

enum MenuBarPopoverLayout {
    static let primaryWidth: CGFloat = 300
    static let networkWidth: CGFloat = 320
    static let minimumHeight: CGFloat = 280
    static let maximumHeight: CGFloat = 500
    static let networkHeaderHeight: CGFloat = 48
    static let networkRowHeight: CGFloat = 42
    static let networkPreferredEdge: NSRectEdge = .maxX

    static func primarySize(for requestedSize: NSSize) -> NSSize {
        NSSize(
            width: primaryWidth,
            height: min(max(requestedSize.height, minimumHeight), maximumHeight)
        )
    }

    static func networkSize(itemCount: Int) -> NSSize {
        let visibleItemCount = min(max(itemCount, 0), 5)
        return NSSize(
            width: networkWidth,
            height: networkHeaderHeight + CGFloat(visibleItemCount) * networkRowHeight
        )
    }
}
