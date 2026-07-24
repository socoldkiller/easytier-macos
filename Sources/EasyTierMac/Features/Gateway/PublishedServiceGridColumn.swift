import SwiftUI

enum PublishedServiceGridColumn: String, CaseIterable, WorkspaceDataGridColumn {
    case service = "Service"
    case ipv4 = "IPv4"
    case target = "Target"
    case authority = "Certificate Authority"
    case challenge = "Challenge"
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
        case .authority: 142
        case .challenge: 98
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
        case .authority: 174
        case .challenge: 116
        case .expires: 191
        case .lastOnline: 182
        case .enabled: 106
        case .more: 64
        }
    }
}
