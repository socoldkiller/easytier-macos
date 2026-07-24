import AppKit
import EasyTierShared
import SwiftUI

struct MemberIdentityCell: View {
    var row: MemberTableRow
    var isHighlighted: Bool
    var onRenameHostname: (NetworkMemberStatus) -> Void
    var onConfigureLocalMember: () -> Void
    var onConfigureRemoteMember: (NetworkMemberStatus) -> Void
    var onPublishService: (NetworkMemberStatus) -> Void

    var body: some View {
        switch row.kind {
        case .member(let member):
            let canInteract = member.isLive
            MemberStatusIdentity(
                member: member,
                isHighlighted: isHighlighted,
                renameAction: canInteract ? { onRenameHostname(member) } : nil,
                configureAction: canInteract
                    ? (member.isLocal
                        ? onConfigureLocalMember
                        : { onConfigureRemoteMember(member) })
                    : nil,
                publishAction: canInteract ? { onPublishService(member) } : nil
            )
        case .publicServerGroup(let group):
            PublicServerGroupIdentity(group: group, isHighlighted: isHighlighted)
        }
    }
}

private struct MemberStatusIdentity: View {
    @Environment(AppContext.self) private var appContext

    var member: NetworkMemberStatus
    var isHighlighted: Bool
    var renameAction: (() -> Void)? = nil
    var configureAction: (() -> Void)? = nil
    var publishAction: (() -> Void)? = nil

    private var store: EasyTierAppStore { appContext.workspace.store }
    private var gateway: GatewayRuntimeController { appContext.runtime.gateway }

    var body: some View {
        if let configureAction {
            Button(action: configureAction) {
                identityContent
                    .workspaceDataGridTwoLineContent()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
            .help("Open Config for this device")
            .accessibilityHint(Text("Opens the Config page for this network."))
            .contextMenu { memberContextMenu }
        } else if renameAction != nil || canPublish {
            identityContent
                .workspaceDataGridTwoLineContent()
                .contextMenu { memberContextMenu }
        } else {
            identityContent
                .workspaceDataGridTwoLineContent()
        }
    }

    private var identityContent: some View {
        HStack(spacing: 8) {
            memberIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(member.hostname)
                    .lineLimit(1)
                Text(memberSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .memberIdentityHighlight(isHighlighted: isHighlighted)
    }

    @ViewBuilder
    private var memberIcon: some View {
        if member.availability == .connecting {
            MemberProgressIndicator(accessibilityLabel: "Connecting")
                .frame(width: 20, height: 20)
        } else {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: member.memberSystemImage)
                    .foregroundStyle(member.memberIconColor)
                Circle()
                    .fill(member.memberStateColor)
                    .frame(width: 7, height: 7)
                    .overlay {
                        Circle()
                            .stroke(.background, lineWidth: 1.5)
                    }
            }
            .frame(width: 20, height: 20)
        }
    }

    @ViewBuilder
    private var memberContextMenu: some View {
        if let ip = member.copyableIPv4Address, !ip.isEmpty {
            Button("Copy IP", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ip, forType: .string)
            }
        }
        if let domain = magicDNSDomain, !domain.isEmpty {
            Button("Copy Domain", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(domain, forType: .string)
            }
        }
        if (!member.peerID.isEmpty && member.peerID != "-")
            || (member.copyableIPv4Address != nil) || magicDNSDomain != nil {
            Divider()
        }
        if !member.peerID.isEmpty, member.peerID != "-" {
            Button("Copy Peer ID", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(member.peerID, forType: .string)
            }
        }
        if let renameAction {
            Button("Rename Hostname...", systemImage: "pencil") {
                renameAction()
            }
        }
        if let configureAction {
            Button("Open Config", systemImage: "slider.horizontal.3") {
                configureAction()
            }
        }
        if canPublish, let publishAction {
            Divider()
            Button("Publish Service…", systemImage: "network.badge.shield.half.filled") {
                publishAction()
            }
        }
    }

    private var magicDNSDomain: String? {
        MagicDNSDisplay.memberDomain(
            hostname: member.hostname,
            config: store.selectedConfig,
            settings: store.magicDNSSettings
        )
    }

    private var canPublish: Bool {
        let availability = PublishedServiceCreationAvailability(
            magicDNSState: gateway.magicDNSState,
            targets: PublishedServiceTargetOption.creationOptions(members: [member])
        )
        return publishAction != nil && availability.isAvailable
    }

    private var memberSubtitle: String {
        [member.memberStateLabel, member.peerIDLabel].compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != "-" }
            .joined(separator: " · ")
    }
}

extension View {
    func pointingHandOnHover() -> some View {
        onHover { hovering in
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

private struct PublicServerGroupIdentity: View {
    var group: PublicServerGroupSummary
    var isHighlighted: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(EasyTierColors.statusConnected)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Public Servers")
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(group.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .workspaceDataGridTwoLineContent()
        .memberIdentityHighlight(isHighlighted: isHighlighted)
    }
}

private struct MemberIdentityHighlight: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var isHighlighted: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(isHighlighted ? 0.08 : 0))
                    .padding(.horizontal, -7)
                    .padding(.vertical, -3)
                    .shadow(color: Color.accentColor.opacity(isHighlighted ? 0.08 : 0), radius: 8, y: 1)
            }
            .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isHighlighted)
    }
}

extension View {
    func memberIdentityHighlight(isHighlighted: Bool) -> some View {
        modifier(MemberIdentityHighlight(isHighlighted: isHighlighted))
    }
}

struct MemberIPv4Cell: View {
    var row: MemberTableRow

    var body: some View {
        switch row.kind {
        case .member(let member):
            CopyableIPv4Cell(member: member)
        case .publicServerGroup:
            Text("-")
                .foregroundStyle(.secondary)
        }
    }
}

struct MemberRouteCell: View {
    var row: MemberTableRow

    var body: some View {
        switch row.kind {
        case .member(let member):
            RouteCostBadge(member: member)
        case .publicServerGroup(let group):
            SummaryBadge(text: group.routeSummary, color: group.routeSummaryColor)
        }
    }
}

struct LatencyMetricText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowPresentationActivity) private var presentationActivity

    var value: String
    var animationsPaused: Bool

    @State private var pulseTrigger = 0

    private var quality: LatencyQuality {
        LatencyQuality(value)
    }

    var body: some View {
        Text(value)
            .fontWeight(.regular)
            .foregroundStyle(quality.color)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: 78, alignment: .leading)
            .contentTransition(shouldAnimate ? .numericText() : .identity)
            .trafficPulse(accent: quality.color, isVisible: shouldShowPulse, trigger: pulseTrigger)
            .animation(shouldAnimate ? .spring(response: 0.26, dampingFraction: 0.72, blendDuration: 0.02) : nil, value: value)
            .onChange(of: value) { oldValue, newValue in
                guard oldValue != newValue else { return }
                if shouldAnimate, oldValue != "-", newValue != "-" {
                    triggerPulse()
                }
            }
        .help(quality.helpText(for: value))
    }

    private var shouldAnimate: Bool {
        presentationActivity.allowsAnimations && !animationsPaused && !reduceMotion
    }

    private var shouldShowPulse: Bool {
        shouldAnimate && quality != .unknown
    }

    private func triggerPulse() {
        pulseTrigger &+= 1
    }
}

struct AnimatedMetricText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowPresentationActivity) private var presentationActivity

    var value: String
    var color: Color = .primary
    var fontWeight: Font.Weight = .regular
    var animates = true

    var body: some View {
        Text(value)
            .fontWeight(fontWeight)
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .contentTransition(shouldAnimate ? .numericText() : .identity)
            .animation(shouldAnimate ? EasyTierMotion.quick(reduceMotion: reduceMotion) : nil, value: value)
    }

    private var shouldAnimate: Bool {
        presentationActivity.allowsAnimations && animates && !reduceMotion
    }
}

struct TrafficMetricText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowPresentationActivity) private var presentationActivity

    var value: String
    var accent: Color
    var animationsPaused: Bool

    @State private var pulseTrigger = 0

    var body: some View {
        Text(value)
            .fontWeight(.medium)
            .foregroundStyle(textColor)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: 78, alignment: .leading)
            .contentTransition(shouldAnimate ? .numericText() : .identity)
            .trafficPulse(accent: accent, isVisible: shouldShowPulse, trigger: pulseTrigger)
            .animation(shouldAnimate ? .spring(response: 0.26, dampingFraction: 0.72, blendDuration: 0.02) : nil, value: value)
            .onChange(of: value) { oldValue, newValue in
                guard oldValue != newValue else { return }
                if shouldAnimate, oldValue != "-", newValue != "-" {
                    triggerPulse()
                }
            }
    }

    private var shouldAnimate: Bool {
        presentationActivity.allowsAnimations && !animationsPaused && !reduceMotion
    }

    private var shouldShowPulse: Bool {
        shouldAnimate && value != "-"
    }

    private var textColor: Color {
        value == "-" ? .primary : accent
    }

    private func triggerPulse() {
        pulseTrigger &+= 1
    }
}

private struct TrafficPulseFrame {
    var opacity: Double = 0
    var width: CGFloat = 16
    var offset: CGFloat = 0

    static let idle = TrafficPulseFrame()
}

extension View {
    func trafficPulse(accent: Color, isVisible: Bool, trigger: Int) -> some View {
        modifier(TrafficPulseModifier(accent: accent, isVisible: isVisible, trigger: trigger))
    }
}

private struct TrafficPulseModifier: ViewModifier {
    var accent: Color
    var isVisible: Bool
    var trigger: Int

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: TrafficPulseFrame.idle, trigger: trigger) { animatedContent, frame in
            animatedContent.trafficPulseOverlay(accent: accent, isVisible: isVisible, frame: frame)
        } keyframes: { _ in
            KeyframeTrack(\.opacity) {
                LinearKeyframe(1, duration: 0.10)
                CubicKeyframe(0, duration: 0.48)
            }
            KeyframeTrack(\.width) {
                CubicKeyframe(58, duration: 0.24)
                CubicKeyframe(16, duration: 0.34)
            }
            KeyframeTrack(\.offset) {
                CubicKeyframe(20, duration: 0.58)
            }
        }
    }
}

extension View {
    nonisolated fileprivate func trafficPulseOverlay(accent: Color, isVisible: Bool, frame: TrafficPulseFrame) -> some View {
        overlay(alignment: .bottomLeading) {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(0),
                            accent.opacity(0.95),
                            accent.opacity(0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: frame.width, height: 2)
                .opacity(isVisible ? frame.opacity : 0)
                .offset(x: frame.offset)
        }
    }
}

private enum LatencyQuality: Equatable {
    case unknown
    case good
    case warning
    case poor

    init(_ value: String) {
        guard let upperBound = value.latencyMillisecondsBounds?.upperBound else {
            self = .unknown
            return
        }

        if upperBound <= 50 {
            self = .good
        } else if upperBound <= 150 {
            self = .warning
        } else {
            self = .poor
        }
    }

    var color: Color {
        switch self {
        case .unknown:
            return .secondary
        case .good:
            return EasyTierColors.statusConnected
        case .warning:
            return EasyTierColors.statusConnecting
        case .poor:
            return EasyTierColors.statusError
        }
    }

    func helpText(for value: String) -> String {
        switch self {
        case .unknown:
            return "Latency unavailable"
        case .good:
            return "Latency \(value): good"
        case .warning:
            return "Latency \(value): moderate"
        case .poor:
            return "Latency \(value): high"
        }
    }
}

private struct SummaryBadge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
    }
}

extension String {
    var millisecondsValue: Int? {
        guard let bounds = latencyMillisecondsBounds, bounds.lowerBound == bounds.upperBound else { return nil }
        return bounds.lowerBound
    }

    var latencyMillisecondsBounds: ClosedRange<Int>? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("ms") else { return nil }

        let valueText = String(trimmed.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = valueText
            .split(separator: "-", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !parts.isEmpty else { return nil }

        let values = parts.compactMap(Int.init)
        guard values.count == parts.count else { return nil }

        guard let first = values.first else { return nil }
        guard let last = values.last else { return first...first }
        return min(first, last)...max(first, last)
    }

    var percentValue: Int? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("%") else { return nil }
        return Int(trimmed.dropLast())
    }
}

extension NetworkMemberStatus {
    var displayedIPv4Address: String {
        let value = copyableIPv4Address ?? virtualIPv4.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "-" : value
    }
}

private struct CopyableIPv4Cell: View {
    @Environment(AppContext.self) private var appContext

    var member: NetworkMemberStatus

    private var store: EasyTierAppStore { appContext.workspace.store }

    var body: some View {
        if member.availability == .assigningAddress {
            MemberProgressIndicator(accessibilityLabel: "Assigning a virtual IPv4 address")
                .help("Assigning a virtual IPv4 address")
        } else if member.availability == .connecting {
            Text(member.displayedIPv4Address)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .help("Last known IPv4 address while reconnecting")
        } else if let ip = member.copyableIPv4Address {
            CopyableIPv4AddressCell(ipv4Address: ip) {
                if let domain = magicDNSDomain {
                    Button("Copy Domain") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(domain, forType: .string)
                    }
                }
            }
        } else {
            Text(member.virtualIPv4)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private var magicDNSDomain: String? {
        MagicDNSDisplay.memberDomain(
            hostname: member.hostname,
            config: store.selectedConfig,
            settings: store.magicDNSSettings
        )
    }
}
