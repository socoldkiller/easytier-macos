import AppKit
import EasyTierShared
import SwiftUI

struct StatusView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(EasyTierAppStore.self) private var store
    @State private var publicServerGroupExpanded = false

    var onConfigureLocalMember: () -> Void = {}

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
                    .transition(reduceMotion ? .opacity : .easyTierSlideFade(edge: .top, distance: 8))
            }

            MotionSwitch(id: contentMotionID, insertionEdge: .bottom) {
                statusContent
            }
        }
        .padding()
        .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: runtimeError)
    }

    @ViewBuilder
    private var statusContent: some View {
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

    private var contentMotionID: String {
        if instance == nil { return "empty-no-running" }
        if members.isEmpty { return "empty-no-members" }
        return "members"
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusBadge(
                title: "Network",
                value: instance?.name ?? store.selectedConfig?.network_name ?? "-",
                systemImage: "globe"
            )
            StatusBadge(title: "Members", value: "\(members.count)", systemImage: "person.2.fill", width: 136)
            StatusBadge(
                title: "Device",
                value: instance?.detail?.dev_name ?? "-",
                systemImage: "desktopcomputer",
                width: 152
            )
            StatusBadge(title: "Mode", value: store.mode.label, systemImage: "slider.horizontal.3")
            Spacer(minLength: 0)
        }
    }

    private var memberTable: some View {
        Table(of: MemberTableRow.self) {
            TableColumn("Member") { row in
                expandablePublicServerCell(for: row) {
                    MemberIdentityCell(
                        row: row,
                        onConfigureLocalMember: onConfigureLocalMember
                    )
                }
            }
            .width(min: 220, ideal: 260, max: 360)

            TableColumn("IPv4") { row in
                expandablePublicServerCell(for: row) {
                    MemberIPv4Cell(row: row)
                }
            }
            .width(ipv4ColumnWidth)

            TableColumn("Route") { row in
                expandablePublicServerCell(for: row) {
                    MemberRouteCell(row: row)
                }
            }
            .width(min: 74, ideal: 96, max: 140)

            TableColumn("Tunnel") { row in
                expandablePublicServerCell(for: row) {
                    Text(row.tunnelProto)
                }
            }
            .width(min: 80, ideal: 92, max: 120)

            TableColumn("Latency") { row in
                expandablePublicServerCell(for: row) {
                    LatencyMetricText(value: row.latency)
                }
            }
            .width(min: 78, ideal: 90, max: 118)

            TableColumn("Upload") { row in
                expandablePublicServerCell(for: row) {
                    AnimatedMetricText(value: row.uploadTotal)
                }
            }
            .width(min: 84, ideal: 96, max: 124)

            TableColumn("Download") { row in
                expandablePublicServerCell(for: row) {
                    AnimatedMetricText(value: row.downloadTotal)
                }
            }
            .width(min: 96, ideal: 108, max: 138)

            TableColumn("Loss") { row in
                expandablePublicServerCell(for: row) {
                    AnimatedMetricText(value: row.lossRate)
                }
            }
            .width(min: 66, ideal: 78, max: 100)

            TableColumn("NAT") { row in
                expandablePublicServerCell(for: row) {
                    Text(row.natType)
                }
            }
            .width(min: 86, ideal: 104, max: 150)

            TableColumn("Version") { row in
                expandablePublicServerCell(for: row) {
                    Text(row.version)
                        .lineLimit(1)
                }
            }
            .width(min: 120, ideal: 150, max: 220)
        } rows: {
            ForEach(memberTableRows) { row in
                if let children = row.children {
                    DisclosureTableRow(row, isExpanded: $publicServerGroupExpanded) {
                        ForEach(children) { child in
                            TableRow(child)
                        }
                    }
                } else {
                    TableRow(row)
                }
            }
        }
        .hiddenScrollIndicators()
    }

    private var memberTableRows: [MemberTableRow] {
        let publicServers = members.filter { !$0.isLocal && $0.isPublicServer }
        guard publicServers.count > 1 else {
            return members.map(MemberTableRow.member)
        }

        let publicServerIDs = Set(publicServers.map(\.id))
        var insertedPublicServerGroup = false

        return members.compactMap { member in
            guard publicServerIDs.contains(member.id) else {
                return .member(member)
            }

            guard !insertedPublicServerGroup else { return nil }
            insertedPublicServerGroup = true
            return .publicServerGroup(publicServers)
        }
    }

    private var ipv4ColumnWidth: CGFloat {
        IPv4CellMetrics.columnWidth(for: members.map(\.displayedIPv4Address))
    }

    @ViewBuilder
    private func expandablePublicServerCell<Content: View>(
        for row: MemberTableRow,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if row.isPublicServerGroup {
            content()
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    togglePublicServerGroup()
                }
                .help(publicServerGroupExpanded ? "Collapse public servers" : "Show public servers")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    togglePublicServerGroup()
                }
        } else {
            content()
        }
    }

    private func togglePublicServerGroup() {
        withAnimation(EasyTierMotion.quick(reduceMotion: reduceMotion)) {
            publicServerGroupExpanded.toggle()
        }
    }
}

private struct MemberTableRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case member(NetworkMemberStatus)
        case publicServerGroup(PublicServerGroupSummary)
    }

    var kind: Kind
    var children: [MemberTableRow]?

    var isPublicServerGroup: Bool {
        if case .publicServerGroup = kind { return true }
        return false
    }

    var id: String {
        switch kind {
        case .member(let member):
            return member.id
        case .publicServerGroup:
            return "public-server-group"
        }
    }

    static func member(_ member: NetworkMemberStatus) -> MemberTableRow {
        MemberTableRow(kind: .member(member), children: nil)
    }

    static func publicServerGroup(_ members: [NetworkMemberStatus]) -> MemberTableRow {
        MemberTableRow(
            kind: .publicServerGroup(PublicServerGroupSummary(members: members)),
            children: members.map(MemberTableRow.member)
        )
    }
}

private struct PublicServerGroupSummary: Equatable {
    var members: [NetworkMemberStatus]

    var count: Int { members.count }

    var subtitle: String {
        ["\(count) online", routeSummary, latencySummary]
            .filter { !$0.isEmpty && $0 != "-" }
            .joined(separator: " · ")
    }

    var routeSummary: String {
        let p2pCount = members.count { $0.routeCost == "P2P" }
        let relayCount = members.count { $0.routeCost.hasPrefix("Relay") }
        let localCount = members.count { $0.routeCost == "Local" }
        let otherCount = max(0, count - p2pCount - relayCount - localCount)

        var parts: [String] = []
        if p2pCount > 0 { parts.append("\(p2pCount) P2P") }
        if relayCount > 0 { parts.append("\(relayCount) Relay") }
        if otherCount > 0 { parts.append("\(otherCount) Other") }
        return parts.isEmpty ? "-" : parts.joined(separator: " + ")
    }

    var routeSummaryColor: Color {
        if members.allSatisfy({ $0.routeCost == "P2P" }) { return Color.green }
        if members.contains(where: { $0.routeCost.hasPrefix("Relay") }) { return Color.orange }
        return Color.secondary
    }

    var tunnelProto: String {
        collapsedUniqueValue(members.map(\.tunnelProto))
    }

    var latencySummary: String {
        let values = members.compactMap { $0.latency.millisecondsValue }
        guard let min = values.min(), let max = values.max() else { return "-" }
        return min == max ? "\(min) ms" : "\(min)-\(max) ms"
    }

    var uploadTotal: String {
        totalBytes(members.map(\.txBytes))
    }

    var downloadTotal: String {
        totalBytes(members.map(\.rxBytes))
    }

    var lossRate: String {
        let values = members.compactMap { $0.lossRate.percentValue }
        guard !values.isEmpty else { return "-" }
        let average = Double(values.reduce(0, +)) / Double(values.count)
        return "\(Int(average.rounded()))%"
    }

    var natType: String {
        collapsedUniqueValue(members.map(\.natType), mixedLabel: "Mixed")
    }

    var version: String {
        let versions = normalizedUniqueValues(members.map(\.version))
        guard !versions.isEmpty else { return "-" }
        return versions.count == 1 ? versions[0] : "\(versions.count) versions"
    }

    private func collapsedUniqueValue(_ values: [String], mixedLabel: String = "Mixed") -> String {
        let uniqueValues = normalizedUniqueValues(values)
        guard !uniqueValues.isEmpty else { return "-" }
        return uniqueValues.count == 1 ? uniqueValues[0] : mixedLabel
    }

    private func normalizedUniqueValues(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0 != "-" })).sorted()
    }

    private func totalBytes(_ values: [Int64]) -> String {
        let total = values.reduce(0, +)
        return total > 0 ? ByteFormatter.format(total) : "-"
    }
}

private extension MemberTableRow {
    var tunnelProto: String {
        switch kind {
        case .member(let member): member.tunnelProto
        case .publicServerGroup(let group): group.tunnelProto
        }
    }

    var latency: String {
        switch kind {
        case .member(let member): member.latency
        case .publicServerGroup(let group): group.latencySummary
        }
    }

    var uploadTotal: String {
        switch kind {
        case .member(let member): member.uploadTotal
        case .publicServerGroup(let group): group.uploadTotal
        }
    }

    var downloadTotal: String {
        switch kind {
        case .member(let member): member.downloadTotal
        case .publicServerGroup(let group): group.downloadTotal
        }
    }

    var lossRate: String {
        switch kind {
        case .member(let member): member.lossRate
        case .publicServerGroup(let group): group.lossRate
        }
    }

    var natType: String {
        switch kind {
        case .member(let member): member.natType
        case .publicServerGroup(let group): group.natType
        }
    }

    var version: String {
        switch kind {
        case .member(let member): member.version
        case .publicServerGroup(let group): group.version
        }
    }
}

private struct MemberIdentityCell: View {
    var row: MemberTableRow
    var onConfigureLocalMember: () -> Void

    var body: some View {
        switch row.kind {
        case .member(let member):
            MemberStatusIdentity(
                member: member,
                configureAction: member.isLocal ? onConfigureLocalMember : nil
            )
        case .publicServerGroup(let group):
            PublicServerGroupIdentity(group: group)
        }
    }
}

private struct MemberStatusIdentity: View {
    var member: NetworkMemberStatus
    var configureAction: (() -> Void)? = nil

    var body: some View {
        if let configureAction {
            Button(action: configureAction) {
                identityContent
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
            .help("Open Config for this device")
            .accessibilityHint(Text("Opens the Config page for this network."))
        } else {
            identityContent
                .padding(.vertical, 5)
        }
    }

    private var identityContent: some View {
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
}

private struct PointingHandOnHover: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard hovering != isHovering else { return }
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
    }
}

private extension View {
    func pointingHandOnHover() -> some View {
        modifier(PointingHandOnHover())
    }
}

private struct PublicServerGroupIdentity: View {
    var group: PublicServerGroupSummary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(Color.green)
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
        .padding(.vertical, 5)
    }
}

private struct MemberIPv4Cell: View {
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

private struct MemberRouteCell: View {
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

private struct LatencyMetricText: View {
    var value: String

    private var quality: LatencyQuality {
        LatencyQuality(value)
    }

    var body: some View {
        AnimatedMetricText(
            value: value,
            color: quality.color,
            fontWeight: .regular
        )
        .help(quality.helpText(for: value))
    }
}

private struct AnimatedMetricText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var value: String
    var color: Color = .primary
    var fontWeight: Font.Weight = .regular

    @State private var isPulsing = false
    @State private var pulseToken = 0

    var body: some View {
        Text(value)
            .fontWeight(fontWeight)
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .scaleEffect(reduceMotion || !isPulsing ? 1 : 1.035, anchor: .leading)
            .opacity(reduceMotion || !isPulsing ? 1 : 0.9)
            .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: value)
            .animation(reduceMotion ? .easeOut(duration: 0.06) : .easeOut(duration: 0.18), value: isPulsing)
            .onChange(of: value) { oldValue, newValue in
                guard oldValue != newValue else { return }
                triggerPulse()
            }
    }

    private func triggerPulse() {
        guard !reduceMotion else { return }

        pulseToken += 1
        let token = pulseToken

        withAnimation(.easeOut(duration: 0.14)) {
            isPulsing = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.18))
            guard token == pulseToken else { return }
            withAnimation(.easeOut(duration: 0.36)) {
                isPulsing = false
            }
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

    var isKnown: Bool {
        self != .unknown
    }

    var color: Color {
        switch self {
        case .unknown:
            return .secondary
        case .good:
            return .green
        case .warning:
            return .orange
        case .poor:
            return .red
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

private extension String {
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

private enum IPv4CellMetrics {
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    static let trailingReservation: CGFloat = 28
    static let minimumWidth: CGFloat = 148
    static let maximumWidth: CGFloat = 220

    static func columnWidth(for values: [String]) -> CGFloat {
        let longest = values.max { textWidth(for: $0) < textWidth(for: $1) } ?? "255.255.255.255"
        return width(for: longest)
    }

    static func width(for value: String) -> CGFloat {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let measuredTextWidth = textWidth(for: text.isEmpty ? "255.255.255.255" : text)
        let targetWidth = measuredTextWidth + horizontalPadding * 2 + trailingReservation
        return min(max(ceil(targetWidth), minimumWidth), maximumWidth)
    }

    private static func textWidth(for value: String) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        return ceil((value as NSString).size(withAttributes: [.font: font]).width)
    }
}

private extension NetworkMemberStatus {
    var displayedIPv4Address: String {
        let value = copyableIPv4Address ?? virtualIPv4.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "-" : value
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
                    .padding(.trailing, IPv4CellMetrics.trailingReservation)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, IPv4CellMetrics.horizontalPadding)
                    .padding(.vertical, IPv4CellMetrics.verticalPadding)
                    .frame(minWidth: IPv4CellMetrics.width(for: ip), alignment: .leading)
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
                            .padding(.trailing, IPv4CellMetrics.horizontalPadding)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var title: String
    var value: String
    var systemImage: String
    var width: CGFloat? = nil

    init(title: String, value: String, systemImage: String, width: CGFloat? = nil) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.width = width
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value.isEmpty ? "-" : value)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.opacity)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(width: width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: value)
    }
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
