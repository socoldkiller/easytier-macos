import SwiftUI

protocol WorkspaceDataGridColumn: Hashable, Identifiable {
    var title: String { get }
    var minimumWidth: CGFloat { get }
    var idealWidth: CGFloat { get }
}
