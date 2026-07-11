import EasyTierShared
import SwiftUI

struct ConnectionEmptyState: View {
    var title: String
    var state: ConnectionGlyphState
    var description: Text

    init(_ title: String, state: ConnectionGlyphState, description: Text) {
        self.title = title
        self.state = state
        self.description = description
    }

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                ConnectionSignalGlyph(state: state, size: 46)
            }
        } description: {
            description
        }
        .padding()
    }
}

private struct ConnectionSignalGlyph: View {
    var state: ConnectionGlyphState
    var size: CGFloat

    var body: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(iconColor)
            .frame(width: size, height: size)
            .accessibilityLabel(accessibilityLabel)
    }

    private var iconColor: Color {
        switch state {
        case .idle: .primary.opacity(0.68)
        case .connecting: .orange
        case .connected: EasyTierColors.statusConnected
        case .error: .red
        }
    }

    private var accessibilityLabel: Text {
        switch state {
        case .idle: Text("Disconnected")
        case .connecting: Text("Connecting")
        case .connected: Text("Connected")
        case .error: Text("Connection error")
        }
    }
}

extension NetworkMemberStatus {
    var memberSystemImage: String {
        if isLocal { return "macbook" }
        if isPublicServer { return "server.rack" }
        return "desktopcomputer"
    }

    var memberIconColor: Color {
        if !isLive { return .secondary }
        if isLocal { return Color.accentColor }
        return memberStateColor
    }

    var memberStateLabel: String {
        if isLocal { return "Local" }
        if isPublicServer { return "Public Server" }
        return "Peer"
    }

    var peerIDLabel: String? {
        let id = peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id != "-" else { return nil }
        return "#\(id)"
    }

    var memberStateColor: Color {
        switch availability {
        case .online:
            return isLocal ? Color.accentColor : EasyTierColors.statusConnected
        case .connecting, .assigningAddress:
            return EasyTierColors.statusConnecting
        }
    }

    var routeCostColor: Color {
        if !isLive { return EasyTierColors.statusConnecting }
        if routeCost == "Local" { return Color.accentColor }
        if routeCost == "P2P" { return EasyTierColors.statusConnected }
        if routeCost.hasPrefix("Relay") { return EasyTierColors.statusConnecting }
        return Color.secondary
    }
}

struct RouteCostBadge: View {
    var member: NetworkMemberStatus

    @ViewBuilder
    var body: some View {
        if member.isLive {
            Text(member.routeCost)
                .font(.caption.weight(.semibold))
                .foregroundStyle(member.routeCostColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(member.routeCostColor.opacity(0.13), in: Capsule())
        } else {
            Text("-")
                .foregroundStyle(.tertiary)
        }
    }
}

struct MemberProgressIndicator: View {
    var accessibilityLabel: String

    var body: some View {
        ProgressView()
            .controlSize(.mini)
            .tint(EasyTierColors.statusConnecting)
            .accessibilityLabel(Text(accessibilityLabel))
    }
}

struct ErrorBanner: View {
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

struct RuntimeIntentConflictBanner: View {
    var intent: RuntimeIntent
    var useRemoteAction: () -> Void
    var reapplyAction: () -> Void
    var keepPendingAction: () -> Void

    private var title: String {
        "Hostname change conflict"
    }

    private var detail: String {
        let target = intent.target.recentHostname ?? intent.target.instanceID ?? intent.target.peerID ?? intent.target.networkName
        let desired = intent.desiredHostname
        return "\(target) changed elsewhere. Saved value: \(desired)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            Button("Use Remote", action: useRemoteAction)
            Button("Reapply", action: reapplyAction)
                .buttonStyle(.borderedProminent)
            Button("Keep Pending", action: keepPendingAction)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
