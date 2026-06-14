import EasyTierShared
import SwiftUI

struct StatusView: View {
    @Environment(EasyTierAppStore.self) private var store

    private var instance: NetworkInstance? { store.selectedRunningInstance }
    private var members: [NetworkMemberStatus] { store.selectedMemberStatuses }
    private var runtimeError: String? {
        instance?.runtimeErrorMessage
    }
    private var connectionState: ConnectionGlyphState {
        if runtimeError != nil { return .error }
        if store.isBusy { return .connecting }
        guard let instance else { return .idle }
        return store.instanceIsFullyConnected(instance) ? .connected : .connecting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let runtimeError {
                ErrorBanner(message: runtimeError)
            }

            if instance == nil {
                ConnectionEmptyState(
                    "No Running Network",
                    state: connectionState,
                    description: Text("Run the selected network to see its members.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if members.isEmpty {
                ConnectionEmptyState(
                    "No Member Information",
                    state: connectionState,
                    description: Text(runtimeError ?? "EasyTier is running, but runtime member details have not arrived yet.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                memberTable
            }
        }
        .padding()
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusBadge(title: "Network", value: instance?.name ?? store.selectedConfig?.network_name ?? "-", connectionState: connectionState)
            StatusBadge(title: "Members", value: "\(members.count)", systemImage: "person.2")
            StatusBadge(title: "Device", value: instance?.detail?.dev_name ?? "-", systemImage: "dot.radiowaves.left.and.right")
            StatusBadge(title: "Mode", value: store.mode.label, systemImage: "switch.2")
            Spacer(minLength: 0)
        }
    }

    private var memberTable: some View {
        Table(members) {
            TableColumn("Member") { member in
                HStack(spacing: 8) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: member.memberSystemImage)
                            .foregroundStyle(member.memberIconColor)
                            .frame(width: 20)
                        Circle()
                            .fill(member.memberStateColor)
                            .frame(width: 7, height: 7)
                            .overlay {
                                Circle()
                                    .stroke(.background, lineWidth: 1.5)
                            }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.hostname)
                            .lineLimit(1)
                        Text("\(member.memberStateLabel) · Peer \(member.peerID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            TableColumn("IPv4") { member in
                Text(member.virtualIPv4)
                    .monospacedDigit()
            }
            TableColumn("Route") { member in
                RouteCostBadge(member: member)
            }
            TableColumn("Tunnel") { member in
                Text(member.tunnelProto)
            }
            TableColumn("Latency") { member in
                Text(member.latency)
                    .monospacedDigit()
            }
            TableColumn("Upload") { member in
                Text(member.uploadTotal)
                    .monospacedDigit()
            }
            TableColumn("Download") { member in
                Text(member.downloadTotal)
                    .monospacedDigit()
            }
            TableColumn("Loss") { member in
                Text(member.lossRate)
                    .monospacedDigit()
            }
            TableColumn("NAT") { member in
                Text(member.natType)
            }
            TableColumn("Version") { member in
                Text(member.version)
                    .lineLimit(1)
            }
        }
    }
}

private struct ConnectionEmptyState: View {
    var title: String
    var state: ConnectionGlyphState
    var description: Text

    init(_ title: String, state: ConnectionGlyphState, description: Text) {
        self.title = title
        self.state = state
        self.description = description
    }

    var body: some View {
        VStack(spacing: 12) {
            ConnectionGlyph(state: state, size: 46)
                .padding(.bottom, 2)
            Text(title)
                .font(.title3.weight(.semibold))
            description
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding()
    }
}

private extension NetworkMemberStatus {
    var memberSystemImage: String {
        if isLocal { return "macbook" }
        if isPublicServer { return "server.rack" }
        return "desktopcomputer"
    }

    var memberIconColor: Color {
        if isLocal { return Color.accentColor }
        return memberStateColor
    }

    var memberStateLabel: String {
        isLocal ? "Local" : "Online"
    }

    var memberStateColor: Color {
        isLocal ? Color.accentColor : Color.green
    }

    var routeCostColor: Color {
        if routeCost == "Local" { return Color.accentColor }
        if routeCost == "P2P" { return Color.green }
        if routeCost.hasPrefix("Relay") { return Color.orange }
        return Color.secondary
    }
}

private struct RouteCostBadge: View {
    var member: NetworkMemberStatus

    var body: some View {
        Text(member.routeCost)
            .font(.caption.weight(.semibold))
            .foregroundStyle(member.routeCostColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(member.routeCostColor.opacity(0.13), in: Capsule())
    }
}

private struct StatusBadge: View {
    var title: String
    var value: String
    var icon: StatusBadgeIcon

    init(title: String, value: String, systemImage: String) {
        self.title = title
        self.value = value
        self.icon = .system(systemImage)
    }

    init(title: String, value: String, connectionState: ConnectionGlyphState) {
        self.title = title
        self.value = value
        self.icon = .connection(connectionState)
    }

    var body: some View {
        HStack(spacing: 9) {
            iconView
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value.isEmpty ? "-" : value)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .system(let systemImage):
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
        case .connection(let state):
            ConnectionGlyph(state: state, size: 22)
        }
    }
}

private enum StatusBadgeIcon {
    case system(String)
    case connection(ConnectionGlyphState)
}

private struct ErrorBanner: View {
    var message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
