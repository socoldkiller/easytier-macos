import SwiftUI

struct WorkspaceDataGridCell<Column: WorkspaceDataGridColumn, Content: View>: View {
    private let column: Column
    private let layout: WorkspaceDataGridLayout<Column>
    private let alignment: Alignment
    private let content: Content

    init(
        _ column: Column,
        layout: WorkspaceDataGridLayout<Column>,
        alignment: Alignment = .leading,
        @ViewBuilder content: () -> Content
    ) {
        self.column = column
        self.layout = layout
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        content
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: layout[column], alignment: alignment)
    }
}
