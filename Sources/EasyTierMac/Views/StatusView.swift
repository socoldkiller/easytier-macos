import AppKit
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
                CopyableIPv4Cell(member: member)
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

private struct CopyableIPv4Cell: View {
    var member: NetworkMemberStatus
    @State private var isHovering = false
    @State private var didCopy = false
    @State private var copyFeedbackToken = 0

    var body: some View {
        if let ip = member.copyableIPv4Address {
            Button {
                copy(ip)
            } label: {
                Text(ip)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.trailing, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(cellBackground)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(cellBorder, lineWidth: isHovering || didCopy ? 1 : 0)
                    }
                    .overlay(alignment: .trailing) {
                        trailingIndicator
                            .padding(.trailing, 7)
                    }
            }
            .buttonStyle(CopyFeedbackButtonStyle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.14)) {
                    isHovering = hovering
                }
            }
            .animation(.easeOut(duration: 0.18), value: didCopy)
            .help(didCopy ? "Copied \(ip)" : "Copy IP \(ip)")
            .contextMenu {
                Button("Copy IP") {
                    copy(ip)
                }
            }
            .accessibilityLabel(Text(didCopy ? "Copied IP \(ip)" : "Copy IP \(ip)"))
            .accessibilityHint(Text("Copies the IPv4 address to the clipboard."))
        } else {
            Text(member.virtualIPv4)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private var trailingIndicator: some View {
        ZStack(alignment: .trailing) {
            if didCopy {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                Image(systemName: isHovering ? "doc.on.doc.fill" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)
                    .opacity(isHovering ? 1 : 0.64)
                    .transition(.opacity)
            }
        }
        .frame(width: 16, alignment: .trailing)
    }

    private var cellBackground: Color {
        if didCopy { return Color.green.opacity(0.16) }
        if isHovering { return Color.accentColor.opacity(0.12) }
        return Color.secondary.opacity(0.06)
    }

    private var cellBorder: Color {
        if didCopy { return Color.green.opacity(0.72) }
        if isHovering { return Color.accentColor.opacity(0.5) }
        return Color.clear
    }

    private func copy(_ ip: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
        copyFeedbackToken += 1
        let token = copyFeedbackToken

        withAnimation(.spring(response: 0.22, dampingFraction: 0.74)) {
            didCopy = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.35))
            guard copyFeedbackToken == token else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                didCopy = false
            }
        }
    }
}

private struct CopyFeedbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
