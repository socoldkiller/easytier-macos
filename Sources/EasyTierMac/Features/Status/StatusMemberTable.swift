import AppKit
import EasyTierShared
import SwiftUI

struct StatusDisplayModel {
    var snapshot: RuntimeStatusSnapshot
    var instance: NetworkInstance?
    var members: [NetworkMemberStatus]
    var runtimeError: String?
    var connectionState: ConnectionGlyphState
    var modeLabel: String
    var memberSearchQuery: SearchQuery
    var filteredMembers: [NetworkMemberStatus]
    var memberRowItems: [MemberGridRowItem]

    init(
        snapshot: RuntimeStatusSnapshot,
        instance: NetworkInstance?,
        members: [NetworkMemberStatus],
        runtimeError: String?,
        connectionState: ConnectionGlyphState,
        modeLabel: String,
        memberSearchQuery: SearchQuery,
        filteredMembers: [NetworkMemberStatus],
        publicServerGroupExpanded: Bool
    ) {
        self.snapshot = snapshot
        self.instance = instance
        self.members = members
        self.runtimeError = runtimeError
        self.connectionState = connectionState
        self.modeLabel = modeLabel
        self.memberSearchQuery = memberSearchQuery
        self.filteredMembers = filteredMembers
        memberRowItems = Self.buildMemberRowItems(
            members: filteredMembers,
            isSearching: !memberSearchQuery.isEmpty,
            publicServerGroupExpanded: publicServerGroupExpanded
        )
    }

    var contentMotionID: String {
        if instance == nil { return "empty-no-running" }
        if members.isEmpty { return "empty-no-members" }
        if !memberSearchQuery.isEmpty, filteredMembers.isEmpty { return "members-search-empty" }
        return "members-\(memberSearchQuery.isEmpty ? "all" : "search")"
    }

    private static func buildMemberRowItems(
        members visibleMembers: [NetworkMemberStatus],
        isSearching: Bool,
        publicServerGroupExpanded: Bool
    ) -> [MemberGridRowItem] {
        let rows = buildMemberRows(members: visibleMembers, isSearching: isSearching)
        var items: [MemberGridRowItem] = []
        items.reserveCapacity(rows.count)

        for row in rows {
            items.append(MemberGridRowItem(row: row, depth: 0, stripeIndex: items.count))
            if publicServerGroupExpanded, let children = row.children {
                items.reserveCapacity(items.count + children.count)
                for child in children {
                    items.append(MemberGridRowItem(row: child, depth: 1, stripeIndex: items.count))
                }
            }
        }

        return items
    }

    private static func buildMemberRows(
        members visibleMembers: [NetworkMemberStatus],
        isSearching: Bool
    ) -> [MemberTableRow] {
        if isSearching {
            return visibleMembers.map(MemberTableRow.member)
        }

        let publicServers = visibleMembers.filter { !$0.isLocal && $0.isPublicServer && $0.isLive }
        guard publicServers.count > 1 else {
            return visibleMembers.map(MemberTableRow.member)
        }

        let publicServerIDs = Set(publicServers.map(\.id))
        var insertedPublicServerGroup = false

        return visibleMembers.compactMap { member in
            guard publicServerIDs.contains(member.id) else {
                return .member(member)
            }

            guard !insertedPublicServerGroup else { return nil }
            insertedPublicServerGroup = true
            return .publicServerGroup(publicServers)
        }
    }
}

struct MemberGridTable: View {
    var rowItems: [MemberGridRowItem]
    var highlightedMemberPeerID: String?
    @Binding var publicServerGroupExpanded: Bool
    @Binding var isScrolling: Bool
    @Binding var globalScrolling: Bool
    var onRenameHostname: (NetworkMemberStatus) -> Void
    var onConfigureLocalMember: () -> Void
    var onConfigureRemoteMember: (NetworkMemberStatus) -> Void

    var body: some View {
        GeometryReader { proxy in
            let widths = MemberGridColumn.widths(for: proxy.size.width)
            let tableWidth = max(proxy.size.width, MemberGridColumn.minimumTotalWidth)

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rowItems) { item in
                            MemberGridRowView(
                                item: item,
                                columnWidths: widths,
                                highlightedMemberPeerID: highlightedMemberPeerID,
                                animationsPaused: isScrolling,
                                isStripedRow: !item.stripeIndex.isMultiple(of: 2),
                                publicServerGroupExpanded: $publicServerGroupExpanded,
                                onRenameHostname: onRenameHostname,
                                onConfigureLocalMember: onConfigureLocalMember,
                                onConfigureRemoteMember: onConfigureRemoteMember
                            )
                        }
                    } header: {
                        MemberGridHeader(columnWidths: widths)
                    }
                }
                .frame(width: tableWidth, alignment: .topLeading)
                .frame(minHeight: proxy.size.height, alignment: .topLeading)
            }
            .scrollIndicators(.hidden, axes: [.vertical, .horizontal])
            .hideScrollViewScrollers()
            .defaultScrollAnchor(.topLeading)
            .trackScrollPhase(isScrolling: $isScrolling)
            .reflectScrollPhase(to: $globalScrolling)
        }
        .onDisappear {
            isScrolling = false
            globalScrolling = false
        }
    }
}

struct MemberGridRowItem: Identifiable {
    fileprivate var row: MemberTableRow
    var depth: Int
    var stripeIndex: Int

    var id: String { "\(row.id)-\(depth)" }
}

private enum MemberGridColumn: String, CaseIterable, Identifiable {
    case member = "Member"
    case ipv4 = "IPv4"
    case route = "Route"
    case tunnel = "Tunnel"
    case latency = "Latency"
    case upload = "Upload"
    case download = "Download"
    case loss = "Loss"
    case nat = "NAT"
    case version = "Version"

    var id: String { rawValue }

    var minWidth: CGFloat {
        switch self {
        case .member: 220
        case .ipv4: 142
        case .route: 88
        case .tunnel: 84
        case .latency: 94
        case .upload: 92
        case .download: 104
        case .loss: 70
        case .nat: 112
        case .version: 132
        }
    }

    var idealWidth: CGFloat {
        switch self {
        case .member: 270
        case .ipv4: 156
        case .route: 96
        case .tunnel: 94
        case .latency: 106
        case .upload: 104
        case .download: 118
        case .loss: 78
        case .nat: 126
        case .version: 148
        }
    }

    static var minimumTotalWidth: CGFloat {
        allCases.reduce(0) { $0 + $1.minWidth }
    }

    private static var idealTotalWidth: CGFloat {
        allCases.reduce(0) { $0 + $1.idealWidth }
    }

    static func widths(for availableWidth: CGFloat) -> [MemberGridColumn: CGFloat] {
        let extraWidth = max(0, availableWidth - minimumTotalWidth)
        let extraIdealWidth = max(1, idealTotalWidth - minimumTotalWidth)
        return Dictionary(uniqueKeysWithValues: allCases.map { column in
            let share = (column.idealWidth - column.minWidth) / extraIdealWidth
            return (column, column.minWidth + extraWidth * share)
        })
    }
}

private struct MemberGridHeader: View {
    var columnWidths: [MemberGridColumn: CGFloat]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MemberGridColumn.allCases) { column in
                Text(column.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(width: columnWidths[column, default: column.minWidth], alignment: .leading)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 0.6, height: 14)
                    }
            }
        }
        .frame(height: 28)
        .background(.background.opacity(0.001))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.6)
        }
    }
}

private struct MemberGridRowView: View {
    var item: MemberGridRowItem
    var columnWidths: [MemberGridColumn: CGFloat]
    var highlightedMemberPeerID: String?
    var animationsPaused: Bool
    var isStripedRow: Bool
    @Binding var publicServerGroupExpanded: Bool
    var onRenameHostname: (NetworkMemberStatus) -> Void
    var onConfigureLocalMember: () -> Void
    var onConfigureRemoteMember: (NetworkMemberStatus) -> Void

    private var row: MemberTableRow { item.row }

    var body: some View {
        HStack(spacing: 0) {
            cell(.member) {
                HStack(spacing: 6) {
                    disclosureControl
                    MemberIdentityCell(
                        row: row,
                        isHighlighted: row.contains(peerID: highlightedMemberPeerID),
                        onRenameHostname: onRenameHostname,
                        onConfigureLocalMember: onConfigureLocalMember,
                        onConfigureRemoteMember: onConfigureRemoteMember
                    )
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
            cell(.ipv4) { MemberIPv4Cell(row: row) }
            cell(.route) { MemberRouteCell(row: row) }
            cell(.tunnel) { Text(row.tunnelProto).lineLimit(1) }
            cell(.latency) { LatencyMetricText(value: row.latency, animationsPaused: animationsPaused) }
            cell(.upload) { TrafficMetricText(value: row.uploadTotal, accent: EasyTierColors.metricUpload, animationsPaused: animationsPaused) }
            cell(.download) { TrafficMetricText(value: row.downloadTotal, accent: EasyTierColors.metricDownload, animationsPaused: animationsPaused) }
            cell(.loss) { AnimatedMetricText(value: row.lossRate, animates: false) }
            cell(.nat) { Text(row.natType).lineLimit(1) }
            cell(.version) { Text(row.version).lineLimit(1) }
        }
        .frame(minHeight: 44)
        .background {
            if isStripedRow {
                Color.primary.opacity(0.025)
            } else {
                Color.clear
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    @ViewBuilder
    private var disclosureControl: some View {
        if row.children != nil {
            Button {
                publicServerGroupExpanded.toggle()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(publicServerGroupExpanded ? 90 : 0))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(publicServerGroupExpanded ? "Collapse public servers" : "Show public servers"))
            .accessibilityValue(Text(publicServerGroupExpanded ? "Expanded" : "Collapsed"))
        } else {
            Color.clear.frame(width: 12)
                .accessibilityHidden(true)
        }
    }

    private func cell<Content: View>(_ column: MemberGridColumn, @ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: columnWidths[column, default: column.minWidth], alignment: .leading)
    }

    private var accessibilitySummary: String {
        [
            "Member: \(row.accessibilityMemberTitle)",
            "Status: \(row.accessibilityStatus)",
            "IPv4: \(row.accessibilityIPv4)",
            "Route: \(row.accessibilityRoute)",
            "Tunnel: \(row.tunnelProto)",
            "Latency: \(row.latency)",
            "Upload: \(row.uploadTotal)",
            "Download: \(row.downloadTotal)",
            "Loss: \(row.lossRate)",
            "NAT: \(row.natType)",
            "Version: \(row.version)",
        ].joined(separator: ", ")
    }
}

struct MemberTableRow: Identifiable, Equatable {
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

private extension MemberTableRow {
    func contains(peerID: String?) -> Bool {
        guard let peerID else { return false }
        switch kind {
        case .member(let member):
            return member.peerID == peerID
        case .publicServerGroup:
            return children?.contains { $0.contains(peerID: peerID) } == true
        }
    }
}

struct RenameHostnameRequest: Identifiable {
    var member: NetworkMemberStatus
    var initialHostname: String

    var id: String {
        "\(member.peerID)-\(member.hostname)"
    }
}

struct RenameHostnameSheet: View {
    @Environment(AppContext.self) private var appContext
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isHostnameFieldFocused: Bool

    var request: RenameHostnameRequest
    var onSave: (String) async -> Bool

    @State private var hostname: String
    @State private var isSaving = false
    @State private var saveError: String?

    private var store: EasyTierAppStore { appContext.workspace.store }

    init(request: RenameHostnameRequest, onSave: @escaping (String) async -> Bool) {
        self.request = request
        self.onSave = onSave
        _hostname = State(initialValue: request.initialHostname)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rename Hostname")
                    .font(.headline)
                Text(request.member.hostname)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            TextField("Hostname", text: $hostname)
                .textFieldStyle(.glassField)
                .focused($isHostnameFieldFocused)
                .disabled(isSaving)
                .onSubmit(save)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isSaving)
                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
        }
        .padding(20)
        .frame(minWidth: 320, idealWidth: 360)
        .onAppear {
            isHostnameFieldFocused = true
        }
        .alert("EasyTier", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            if await onSave(hostname) {
                dismiss()
            } else {
                saveError = store.lastError ?? "Rename hostname failed."
                store.lastError = nil
            }
            isSaving = false
        }
    }
}

struct MemberSearchField: View {
    @Binding var text: String
    var resultCount: Int
    var totalCount: Int

    private var isSearching: Bool {
        !SearchQuery(text).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)

            TextField("Search networks, hostnames, servers, IPs, Peer IDs", text: $text)
                .textFieldStyle(.plain)

            if isSearching {
                Text("\(resultCount)/\(totalCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear search")
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frostedGlassBackground(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.primary.opacity(0.055), lineWidth: 1)
        }
    }
}

struct PublicServerGroupSummary: Equatable {
    private enum RouteTone: Equatable {
        case connected
        case connecting
        case secondary
    }

    var count: Int
    var subtitle: String
    var routeSummary: String
    var tunnelProto: String
    var latencySummary: String
    var uploadTotal: String
    var downloadTotal: String
    var lossRate: String
    var natType: String
    var version: String

    private var routeTone: RouteTone

    init(members: [NetworkMemberStatus]) {
        count = members.count
        routeSummary = Self.routeSummary(members: members)
        tunnelProto = Self.collapsedUniqueValue(members.map(\.tunnelProto))
        latencySummary = Self.latencySummary(members: members)
        uploadTotal = Self.totalBytes(members.map(\.txBytes))
        downloadTotal = Self.totalBytes(members.map(\.rxBytes))
        lossRate = Self.lossRate(members: members)
        natType = Self.collapsedUniqueValue(members.map(\.natType), mixedLabel: "Mixed")
        version = Self.version(members: members)
        routeTone = Self.routeTone(members: members)
        subtitle = ["\(count) online", routeSummary, latencySummary]
            .filter { !$0.isEmpty && $0 != "-" }
            .joined(separator: " · ")
    }

    var routeSummaryColor: Color {
        switch routeTone {
        case .connected: EasyTierColors.statusConnected
        case .connecting: EasyTierColors.statusConnecting
        case .secondary: Color.secondary
        }
    }

    private static func routeSummary(members: [NetworkMemberStatus]) -> String {
        let p2pCount = members.count { $0.routeCost == "P2P" }
        let relayCount = members.count { $0.routeCost.hasPrefix("Relay") }
        let localCount = members.count { $0.routeCost == "Local" }
        let otherCount = max(0, members.count - p2pCount - relayCount - localCount)

        var parts: [String] = []
        if p2pCount > 0 { parts.append("\(p2pCount) P2P") }
        if relayCount > 0 { parts.append("\(relayCount) Relay") }
        if otherCount > 0 { parts.append("\(otherCount) Other") }
        return parts.isEmpty ? "-" : parts.joined(separator: " + ")
    }

    private static func routeTone(members: [NetworkMemberStatus]) -> RouteTone {
        if members.allSatisfy({ $0.routeCost == "P2P" }) { return .connected }
        if members.contains(where: { $0.routeCost.hasPrefix("Relay") }) { return .connecting }
        return .secondary
    }

    private static func latencySummary(members: [NetworkMemberStatus]) -> String {
        let values = members.compactMap { $0.latency.millisecondsValue }
        guard let min = values.min(), let max = values.max() else { return "-" }
        return min == max ? "\(min) ms" : "\(min)-\(max) ms"
    }

    private static func lossRate(members: [NetworkMemberStatus]) -> String {
        let values = members.compactMap { $0.lossRate.percentValue }
        guard !values.isEmpty else { return "-" }
        let average = Double(values.reduce(0, +)) / Double(values.count)
        return "\(Int(average.rounded()))%"
    }

    private static func version(members: [NetworkMemberStatus]) -> String {
        let versions = normalizedUniqueValues(members.map(\.version))
        guard !versions.isEmpty else { return "-" }
        return versions.count == 1 ? versions[0] : "\(versions.count) versions"
    }

    private static func collapsedUniqueValue(_ values: [String], mixedLabel: String = "Mixed") -> String {
        let uniqueValues = normalizedUniqueValues(values)
        guard !uniqueValues.isEmpty else { return "-" }
        return uniqueValues.count == 1 ? uniqueValues[0] : mixedLabel
    }

    private static func normalizedUniqueValues(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0 != "-" })).sorted()
    }

    private static func totalBytes(_ values: [Int64]) -> String {
        let total = values.reduce(0, +)
        return total > 0 ? ByteFormatter.format(total) : "-"
    }
}

private extension MemberTableRow {
    var accessibilityMemberTitle: String {
        switch kind {
        case .member(let member): member.hostname
        case .publicServerGroup(let group): "Public servers, \(group.count) online"
        }
    }

    var accessibilityStatus: String {
        switch kind {
        case .member(let member):
            switch member.availability {
            case .online: "Online"
            case .connecting: "Connecting"
            case .assigningAddress: "Assigning a virtual IPv4 address"
            }
        case .publicServerGroup:
            "Online"
        }
    }

    var accessibilityIPv4: String {
        switch kind {
        case .member(let member): member.displayedIPv4Address
        case .publicServerGroup: "-"
        }
    }

    var accessibilityRoute: String {
        switch kind {
        case .member(let member): member.routeCost
        case .publicServerGroup(let group): group.routeSummary
        }
    }

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
