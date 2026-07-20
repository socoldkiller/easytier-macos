import SwiftUI

struct WorkspaceDataGrid<
    Row: Identifiable,
    Column: WorkspaceDataGridColumn,
    RowContent: View
>: View {
    private let rows: [Row]
    private let columns: [Column]
    private let minimumRowHeight: CGFloat
    @Binding private var isScrolling: Bool
    @Binding private var globalScrolling: Bool
    private let rowContent: (Row, WorkspaceDataGridLayout<Column>) -> RowContent

    init(
        rows: [Row],
        columns: [Column],
        minimumRowHeight: CGFloat,
        isScrolling: Binding<Bool>,
        globalScrolling: Binding<Bool>,
        @ViewBuilder rowContent: @escaping (
            Row,
            WorkspaceDataGridLayout<Column>
        ) -> RowContent
    ) {
        self.rows = rows
        self.columns = columns
        self.minimumRowHeight = minimumRowHeight
        _isScrolling = isScrolling
        _globalScrolling = globalScrolling
        self.rowContent = rowContent
    }

    var body: some View {
        let rowOffsets = rowOffsets

        GeometryReader { proxy in
            let layout = WorkspaceDataGridLayout(
                columns: columns,
                availableWidth: proxy.size.width
            )

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rows) { row in
                            rowContent(row, layout)
                                // Keep row decoration aligned with the table when column widths round differently.
                                .frame(
                                    width: layout.tableWidth,
                                    height: nil,
                                    alignment: .topLeading
                                )
                                .frame(minHeight: minimumRowHeight)
                                .background {
                                    if !rowOffsets[row.id, default: 0].isMultiple(of: 2) {
                                        Color.primary.opacity(0.025)
                                    } else {
                                        Color.clear
                                    }
                                }
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.07))
                                        .frame(height: 0.6)
                                }
                        }
                    } header: {
                        WorkspaceDataGridHeader(columns: columns, layout: layout)
                    }
                }
                .frame(width: layout.tableWidth, alignment: .topLeading)
                .frame(minHeight: proxy.size.height, alignment: .topLeading)
            }
            .scrollIndicators(.hidden, axes: [.vertical, .horizontal])
            .hideScrollViewScrollers()
            .defaultScrollAnchor(.topLeading)
            .onScrollPhaseChange { _, phase in
                isScrolling = phase.isScrolling
                globalScrolling = phase.isScrolling
            }
        }
        .onDisappear {
            isScrolling = false
            globalScrolling = false
        }
    }

    private var rowOffsets: [Row.ID: Int] {
        var offsets: [Row.ID: Int] = [:]
        for index in rows.indices {
            offsets[rows[index].id] = index
        }
        return offsets
    }
}
