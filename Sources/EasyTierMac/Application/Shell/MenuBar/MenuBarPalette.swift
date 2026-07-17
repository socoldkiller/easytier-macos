import SwiftUI

enum MenuBarPalette {
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let mutedText = Color.secondary.opacity(0.6)
    static let divider = Color.primary.opacity(0.14)
    static let rowHighlight = Color.primary.opacity(0.08)
    static let selectedRow = EasyTierColors.menuBarSelectedRow
    static let selectedRowHorizontalInset: CGFloat = 12
    static let selectedRowVerticalInset: CGFloat = 5
    static let selectedRowContentVerticalPadding: CGFloat = 4
    static let connected = EasyTierColors.menuBarConnected
    static let selectedRowText = Color(nsColor: .selectedMenuItemTextColor)
}
