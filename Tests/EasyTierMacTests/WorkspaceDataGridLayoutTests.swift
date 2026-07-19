import CoreGraphics
import Testing
@testable import EasyTierMac

@Test func workspaceDataGridKeepsColumnMinimumsInANarrowContainer() {
    let layout = WorkspaceDataGridLayout(
        columns: WorkspaceDataGridTestColumn.allCases,
        availableWidth: 100
    )

    #expect(layout.tableWidth == 180)
    #expect(layout[.primary] == 100)
    #expect(layout[.secondary] == 80)
}

@Test func workspaceDataGridDistributesExtraWidthByColumnFlexibility() {
    let layout = WorkspaceDataGridLayout(
        columns: WorkspaceDataGridTestColumn.allCases,
        availableWidth: 300
    )

    #expect(layout.tableWidth == 300)
    #expect(layout[.primary] == 148)
    #expect(layout[.secondary] == 152)
}

private enum WorkspaceDataGridTestColumn: CaseIterable, WorkspaceDataGridColumn {
    case primary
    case secondary

    var id: Self { self }
    var title: String { String(describing: self) }

    var minimumWidth: CGFloat {
        switch self {
        case .primary: 100
        case .secondary: 80
        }
    }

    var idealWidth: CGFloat {
        switch self {
        case .primary: 140
        case .secondary: 140
        }
    }
}
