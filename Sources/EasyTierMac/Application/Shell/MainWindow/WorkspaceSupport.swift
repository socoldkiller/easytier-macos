@preconcurrency import AppKit
import EasyTierShared
import SwiftUI

struct TOMLPresentation: Identifiable {
    let id = UUID()
    var mode: TOMLSheet.Mode
    var text: String
}
struct WorkspaceTabPicker: View {
    @Binding var selection: WorkspaceTab
    var tabs: [WorkspaceTab]

    private static let preferredWidth: CGFloat = 360
    var body: some View {
        Picker("Workspace", selection: $selection) {
            ForEach(tabs) { tab in
                Label(tab.displayTitle, systemImage: tab.systemImage)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.regular)
        .labelsHidden()
        .frame(width: Self.preferredWidth)
        .help("Switch workspace view")
        .accessibilityLabel(Text("Workspace"))
    }
}

struct NetworkSearchResult: Identifiable {
    var id: String
    var networkID: String
    var title: String
    var subtitle: String
    var sourceLabel: String
    var matchDescription: String?
    var systemImage: String
    var state: ConnectionGlyphState?
    var targetTab: WorkspaceTab?
    var highlightedPeerID: String?

    static func network(
        id: String,
        networkID: String,
        title: String,
        subtitle: String,
        state: ConnectionGlyphState,
        matchDescription: String?
    ) -> NetworkSearchResult {
        NetworkSearchResult(
            id: id,
            networkID: networkID,
            title: title,
            subtitle: subtitle,
            sourceLabel: "Network",
            matchDescription: matchDescription,
            systemImage: "network",
            state: state,
            targetTab: nil,
            highlightedPeerID: nil
        )
    }

    static func device(
        id: String,
        networkID: String,
        title: String,
        subtitle: String,
        sourceLabel: String,
        matchDescription: String?,
        systemImage: String,
        targetTab: WorkspaceTab?,
        highlightedPeerID: String?
    ) -> NetworkSearchResult {
        NetworkSearchResult(
            id: id,
            networkID: networkID,
            title: title,
            subtitle: subtitle,
            sourceLabel: sourceLabel,
            matchDescription: matchDescription,
            systemImage: systemImage,
            state: nil,
            targetTab: targetTab,
            highlightedPeerID: highlightedPeerID
        )
    }
}

struct NetworkSearchResultRow: View {
    var result: NetworkSearchResult

    var body: some View {
        HStack(spacing: 10) {
            if let state = result.state {
                NetworkStatusGlyph(state: state)
            } else {
                Image(systemName: result.systemImage)
                    .font(.headline)
                    .foregroundStyle(.tint)
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(result.title)
                        .lineLimit(1)
                    Text(result.sourceLabel)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background {
                            Capsule(style: .continuous)
                                .fill(.secondary.opacity(0.13))
                        }
                }
                if let matchDescription = result.matchDescription {
                    Text(matchDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(result.subtitle)
                    .font(result.matchDescription == nil ? .caption : .caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(result.matchDescription == nil ? 2 : 1)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SearchResultField: Equatable {
    var label: String
    var searchValue: String
    var displayValue: String

    init(_ label: String, _ searchValue: String, displayValue: String? = nil) {
        self.label = label
        self.searchValue = searchValue
        self.displayValue = displayValue ?? searchValue
    }
}

extension Array where Element == SearchResultField {
    var searchValues: [String] {
        map(\.searchValue)
    }

    func matchingTokens(from query: SearchQuery) -> [SearchResultField] {
        var seen = Set<String>()

        return filter { field in
            guard !field.searchValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            let key = "\(field.label)\u{0}\(field.displayValue)"
            guard seen.insert(key).inserted else { return false }

            return query.tokens.contains { token in
                SearchQuery(token).matches([field.searchValue])
            }
        }
    }
}

struct SearchKeyboardBridge: NSViewRepresentable {
    nonisolated(unsafe) var isActive: Bool
    nonisolated(unsafe) var onUp: () -> Void
    nonisolated(unsafe) var onDown: () -> Void
    nonisolated(unsafe) var onReturn: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.view = nsView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator {
        nonisolated(unsafe) var parent: SearchKeyboardBridge
        nonisolated(unsafe) weak var view: NSView?
        private var monitor: Any?

        init(parent: SearchKeyboardBridge) {
            self.parent = parent
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard parent.isActive else { return event }
            guard !event.modifierFlags.containsAny(of: [.command, .option, .control]) else {
                return event
            }

            switch event.keyCode {
            case Self.upArrowKeyCode:
                parent.onUp()
                return nil
            case Self.downArrowKeyCode:
                parent.onDown()
                return nil
            case Self.returnKeyCode, Self.keypadEnterKeyCode:
                parent.onReturn()
                return nil
            default:
                return event
            }
        }

        private static let returnKeyCode: UInt16 = 36
        private static let keypadEnterKeyCode: UInt16 = 76
        private static let downArrowKeyCode: UInt16 = 125
        private static let upArrowKeyCode: UInt16 = 126
    }
}

private extension NSEvent.ModifierFlags {
    func containsAny(of flags: NSEvent.ModifierFlags) -> Bool {
        !intersection(flags).isEmpty
    }
}

extension WorkspaceTab {
    static let displayOrder: [WorkspaceTab] = [.status, .services, .view, .config, .peers, .logs]

    var motionIndex: Int {
        WorkspaceTab.displayOrder.firstIndex(where: { $0.id == id }) ?? 0
    }

    var systemImage: String {
        switch self {
        case .status:
            return "dot.radiowaves.left.and.right"
        case .services:
            return "network.badge.shield.half.filled"
        case .view:
            return "chart.xyaxis.line"
        case .config:
            return "slider.horizontal.3"
        case .logs:
            return "doc.text.magnifyingglass"
        case .peers:
            return "wifi"
        }
    }
}

struct NetworkRow: View {
    var stored: NetworkConfig
    var state: ConnectionGlyphState

    var body: some View {
        HStack(spacing: 10) {
            NetworkStatusGlyph(state: state)
            VStack(alignment: .leading, spacing: 2) {
                Text(stored.network_name)
                    .lineLimit(1)
                if let hostname = stored.hostname?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty {
                    Text(hostname)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct NetworkStatusGlyph: View {
    var state: ConnectionGlyphState

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "network")
                .font(.headline)
                .foregroundStyle(iconColor)
                .frame(width: 18, height: 18)

            Circle()
                .fill(statusColor)
                .frame(width: 5.5, height: 5.5)
                .offset(x: 1.5, y: 1.5)
        }
            .frame(width: 22, height: 22)
            .accessibilityLabel(accessibilityLabel)
    }

    private var iconColor: Color {
        switch state {
        case .connected, .connecting:
            return .primary.opacity(0.82)
        case .idle, .error:
            return .secondary
        }
    }

    private var statusColor: Color {
        switch state {
        case .connected:
            return .green
        case .idle:
            return .secondary
        case .connecting:
            return .orange
        case .error:
            return .red
        }
    }

    private var accessibilityLabel: Text {
        switch state {
        case .connected:
            return Text("Running")
        case .idle:
            return Text("Stopped")
        case .connecting:
            return Text("Connecting")
        case .error:
            return Text("Connection error")
        }
    }
}
