import SwiftUI

struct WorkspaceDataGridHeader<Column: WorkspaceDataGridColumn>: View {
    let columns: [Column]
    let layout: WorkspaceDataGridLayout<Column>

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                Text(column.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(width: layout[column], alignment: .leading)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 0.6, height: 14)
                    }
            }
        }
        .frame(width: layout.tableWidth, height: 28, alignment: .leading)
        .background(.background.opacity(0.001))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.6)
        }
    }
}
