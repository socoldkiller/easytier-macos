import SwiftUI

struct WorkspaceDataGridLayout<Column: WorkspaceDataGridColumn> {
    private var widths: [Column: CGFloat]

    let tableWidth: CGFloat

    init(columns: [Column], availableWidth: CGFloat) {
        let minimumTotalWidth = columns.reduce(0) { $0 + $1.minimumWidth }
        let resolvedTableWidth = max(max(availableWidth, 0), minimumTotalWidth)
        let extraWidth = resolvedTableWidth - minimumTotalWidth
        let flexibleWidth = columns.reduce(0) {
            $0 + max(0, $1.idealWidth - $1.minimumWidth)
        }
        let equalShare = columns.isEmpty ? 0 : extraWidth / CGFloat(columns.count)

        var resolvedWidths: [Column: CGFloat] = [:]
        for column in columns {
            let columnFlex = max(0, column.idealWidth - column.minimumWidth)
            let additionalWidth = flexibleWidth > 0
                ? extraWidth * columnFlex / flexibleWidth
                : equalShare
            resolvedWidths[column] = column.minimumWidth + additionalWidth
        }

        widths = resolvedWidths
        tableWidth = resolvedTableWidth
    }

    subscript(column: Column) -> CGFloat {
        widths[column, default: column.minimumWidth]
    }
}
