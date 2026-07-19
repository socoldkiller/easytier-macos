import SwiftUI

enum PublishedServiceGridColumn: String, CaseIterable, WorkspaceDataGridColumn {
    case domain = "Domain"
    case proxyIPv4 = "Proxy IPv4"
    case port = "Port"
    case `protocol` = "Protocol"
    case ssl = "SSL"
    case status = "Status"
    case lastOnline = "Last Online"
    case more = ""

    var id: Self { self }
    var title: String { rawValue }

    var minimumWidth: CGFloat {
        switch self {
        case .domain: 320
        case .proxyIPv4: 130
        case .port: 70
        case .protocol: 80
        case .ssl: 130
        case .status: 180
        case .lastOnline: 145
        case .more: 44
        }
    }

    var idealWidth: CGFloat {
        switch self {
        case .domain: 380
        case .proxyIPv4: 150
        case .port: 80
        case .protocol: 90
        case .ssl: 150
        case .status: 205
        case .lastOnline: 170
        case .more: 44
        }
    }
}
