import SwiftUI

enum PublishedServiceGridColumn: String, CaseIterable, WorkspaceDataGridColumn {
    case service = "Service"
    case ipv4 = "IPv4"
    case target = "Target"
    case ssl = "HTTPS"
    case expires = "Expires"
    case lastOnline = "Last Online"
    case enabled = "Enabled"
    case more = ""

    var id: Self { self }
    var title: String { rawValue }

    var minimumWidth: CGFloat {
        switch self {
        case .service: 324
        case .ipv4: 142
        case .target: 248
        case .ssl: 130
        case .expires: 162
        case .lastOnline: 128
        case .enabled: 88
        case .more: 58
        }
    }

    var idealWidth: CGFloat {
        switch self {
        case .service: 398
        case .ipv4: 156
        case .target: 336
        case .ssl: 163
        case .expires: 191
        case .lastOnline: 182
        case .enabled: 106
        case .more: 64
        }
    }
}
