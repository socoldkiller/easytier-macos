import AppKit
import EasyTierShared
import SwiftUI

struct StatusView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(EasyTierAppStore.self) private var store
    @Environment(AppAppearanceSettings.self) private var appearanceSettings
    @State private var publicServerGroupExpanded = false
    @State private var renameHostnameRequest: RenameHostnameRequest?
    @State private var memberSearchText = ""
    @State private var memberTableIsScrolling = false
    @State private var displayedMembers: [NetworkMemberStatus] = []

    var highlightedMemberPeerID: String? = nil
    var onRenameLocalHostname: (String) -> Void = { _ in }
    var onRenameRemoteHostname: (NetworkMemberStatus, String) async -> Bool = { _, _ in false }
    var onConfigureLocalMember: () -> Void = {}

    private var instance: NetworkInstance? { store.selectedRunningInstance }
    private var members: [NetworkMemberStatus] { store.selectedMemberStatuses }
    private var runtimeError: String? {
        var inst = instance
        inst?.detail = store.selectedRuntimeDetail
        return inst?.runtimeErrorMessage
    }
    private var runtimeIntentConflict: RuntimeIntent? {
        let networkName = instance?.name ?? store.selectedConfig?.network_name
        return store.runtimeIntents.first { intent in
            intent.status == .conflict && (networkName == nil || intent.target.networkName == networkName)
        }
    }
    private var connectionState: ConnectionGlyphState {
        if runtimeError != nil { return .error }
        if store.isBusy { return .connecting }
        guard let instance else { return .idle }
        var inst = instance
        inst.detail = store.selectedRuntimeDetail
        return store.instanceIsFullyConnected(inst) ? .connected : .connecting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if instance != nil, !members.isEmpty || !memberSearchQuery.isEmpty {
                MemberSearchField(
                    text: $memberSearchText,
                    resultCount: filteredMembers.count,
                    totalCount: members.count
                )
            }

            if let runtimeError {
                ErrorBanner(message: runtimeError)
                    .transition(reduceMotion ? .opacity : .easyTierSlideFade(edge: .top, distance: 8))
            }

            if let conflict = runtimeIntentConflict {
                RuntimeIntentConflictBanner(
                    intent: conflict,
                    useRemoteAction: { store.useRemoteValue(forRuntimeIntent: conflict.id) },
                    reapplyAction: {
                        Task {
                            await store.reapplyRuntimeIntent(conflict.id)
                        }
                    },
                    keepPendingAction: { store.keepRuntimeIntentPending(conflict.id) }
                )
                .transition(reduceMotion ? .opacity : .easyTierSlideFade(edge: .top, distance: 8))
            }

            MotionSwitch(id: contentMotionID, insertionEdge: .bottom) {
                statusContent
            }
        }
        .padding()
        .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: runtimeError)
        .onAppear { displayedMembers = members }
        .onChange(of: members) { _, newMembers in
            guard !memberTableIsScrolling else { return }
            displayedMembers = newMembers
        }
        .onChange(of: memberTableIsScrolling) { _, isScrolling in
            guard !isScrolling else { return }
            displayedMembers = members
        }
        .sheet(item: $renameHostnameRequest) { request in
            RenameHostnameSheet(request: request) { hostname in
                if request.member.isLocal {
                    onRenameLocalHostname(hostname)
                    return true
                } else {
                    return await onRenameRemoteHostname(request.member, hostname)
                }
            }
        }
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
        } else if !memberSearchQuery.isEmpty, filteredMembers.isEmpty {
            ContentUnavailableView(
                "No Search Results",
                systemImage: "magnifyingglass",
                description: Text("Try a network name, hostname, server role, IP address, route, NAT type, version, or Peer ID.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            memberTable
        }
    }

    private var contentMotionID: String {
        if instance == nil { return "empty-no-running" }
        if members.isEmpty { return "empty-no-members" }
        if !memberSearchQuery.isEmpty, filteredMembers.isEmpty { return "members-search-empty" }
        return "members-\(memberSearchQuery.isEmpty ? "all" : "search")"
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
                value: store.selectedRuntimeDetail?.dev_name ?? instance?.detail?.dev_name ?? "-",
                systemImage: "desktopcomputer",
                width: 152
            )
            StatusBadge(title: "Mode", value: store.mode.label, systemImage: "slider.horizontal.3")
            Spacer(minLength: 0)
        }
    }

    private var memberTable: some View {
        MemberGridTable(
            rows: memberTableRows,
            highlightedMemberPeerID: highlightedMemberPeerID,
            publicServerGroupExpanded: $publicServerGroupExpanded,
            isScrolling: $memberTableIsScrolling,
            onRenameHostname: beginRenamingHostname,
            onConfigureLocalMember: onConfigureLocalMember
        )
    }

    private var memberTableRows: [MemberTableRow] {
        let visibleMembers = filteredMembers
        if !memberSearchQuery.isEmpty {
            return visibleMembers.map(MemberTableRow.member)
        }

        let publicServers = visibleMembers.filter { !$0.isLocal && $0.isPublicServer }
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

    private var memberSearchQuery: SearchQuery {
        SearchQuery(memberSearchText)
    }

    private var tableMembers: [NetworkMemberStatus] {
        memberTableIsScrolling && !displayedMembers.isEmpty ? displayedMembers : members
    }

    private var filteredMembers: [NetworkMemberStatus] {
        let query = memberSearchQuery
        guard !query.isEmpty else { return tableMembers }
        if query.matches(networkSearchFields) { return tableMembers }
        return tableMembers.filter { member in
            query.matches(member.searchFields)
        }
    }

    private var networkSearchFields: [String] {
        var fields = [
            instance?.name ?? "",
            instance?.instance_id ?? "",
            instance?.detail?.dev_name ?? "",
            instance?.detail?.error_msg ?? "",
            store.selectedConfigID ?? "",
            store.selectedConfig?.network_name ?? "",
            store.selectedConfig?.instance_id ?? "",
            store.mode.label,
            connectionState.searchLabel,
        ]

        if let config = store.selectedConfig {
            fields.append(contentsOf: [
                config.hostname ?? "",
                config.virtual_ipv4,
                config.public_server_url,
                config.dev_name,
                config.networking_method.searchLabel,
            ])
            fields.append(contentsOf: config.peer_urls)
            fields.append(contentsOf: config.listener_urls)
            fields.append(contentsOf: config.proxy_cidrs)
            fields.append(contentsOf: config.routes)
            fields.append(contentsOf: config.exit_nodes)
            fields.append(contentsOf: config.enabledSearchFeatureLabels)
        }

        return fields
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

    private func beginRenamingHostname(_ member: NetworkMemberStatus) {
        let configuredHostname = store.selectedConfig?.hostname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialHostname: String
        if member.isLocal, let configuredHostname, !configuredHostname.isEmpty {
            initialHostname = configuredHostname
        } else {
            initialHostname = member.hostname
        }
        renameHostnameRequest = RenameHostnameRequest(
            member: member,
            initialHostname: initialHostname
        )
    }

}

private struct MemberGridTable: View {
    var rows: [MemberTableRow]
    var highlightedMemberPeerID: String?
    @Binding var publicServerGroupExpanded: Bool
    @Binding var isScrolling: Bool
    var onRenameHostname: (NetworkMemberStatus) -> Void
    var onConfigureLocalMember: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let widths = MemberGridColumn.widths(for: proxy.size.width)
            let tableWidth = max(proxy.size.width, MemberGridColumn.minimumTotalWidth)

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(flattenedRows) { item in
                            MemberGridRowView(
                                item: item,
                                columnWidths: widths,
                                highlightedMemberPeerID: highlightedMemberPeerID,
                                publicServerGroupExpanded: $publicServerGroupExpanded,
                                onRenameHostname: onRenameHostname,
                                onConfigureLocalMember: onConfigureLocalMember
                            )
                        }
                    } header: {
                        MemberGridHeader(columnWidths: widths)
                    }
                }
                .frame(width: tableWidth, alignment: .topLeading)
            }
            .scrollIndicators(.never, axes: [.vertical, .horizontal])
            .defaultScrollAnchor(.topLeading)
            .trackScrollPhase(isScrolling: $isScrolling)
        }
    }

    private var flattenedRows: [MemberGridRowItem] {
        rows.flatMap { row -> [MemberGridRowItem] in
            guard let children = row.children else {
                return [.init(row: row, depth: 0)]
            }

            var result = [MemberGridRowItem(row: row, depth: 0)]
            if publicServerGroupExpanded {
                result += children.map { MemberGridRowItem(row: $0, depth: 1) }
            }
            return result
        }
    }
}

private struct MemberGridRowItem: Identifiable {
    var row: MemberTableRow
    var depth: Int

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
    @Binding var publicServerGroupExpanded: Bool
    var onRenameHostname: (NetworkMemberStatus) -> Void
    var onConfigureLocalMember: () -> Void

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
                        onConfigureLocalMember: onConfigureLocalMember
                    )
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
            cell(.ipv4) { MemberIPv4Cell(row: row) }
            cell(.route) { MemberRouteCell(row: row) }
            cell(.tunnel) { Text(row.tunnelProto).lineLimit(1) }
            cell(.latency) { LatencyMetricText(value: row.latency, animates: false) }
            cell(.upload) { AnimatedMetricText(value: row.uploadTotal, animates: false) }
            cell(.download) { AnimatedMetricText(value: row.downloadTotal, animates: false) }
            cell(.loss) { AnimatedMetricText(value: row.lossRate, animates: false) }
            cell(.nat) { Text(row.natType).lineLimit(1) }
            cell(.version) { Text(row.version).lineLimit(1) }
        }
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.6)
        }
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
        } else {
            Color.clear.frame(width: 12)
        }
    }

    private func cell<Content: View>(_ column: MemberGridColumn, @ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: columnWidths[column, default: column.minWidth], alignment: .leading)
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

private struct RenameHostnameRequest: Identifiable {
    var member: NetworkMemberStatus
    var initialHostname: String

    var id: String {
        "\(member.peerID)-\(member.hostname)"
    }
}

private struct RenameHostnameSheet: View {
    @Environment(EasyTierAppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isHostnameFieldFocused: Bool

    var request: RenameHostnameRequest
    var onSave: (String) async -> Bool

    @State private var hostname: String
    @State private var isSaving = false
    @State private var saveError: String?

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
        .frame(width: 360)
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

private struct MemberSearchField: View {
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
    var isHighlighted: Bool
    var onRenameHostname: (NetworkMemberStatus) -> Void
    var onConfigureLocalMember: () -> Void

    var body: some View {
        switch row.kind {
        case .member(let member):
            MemberStatusIdentity(
                member: member,
                isHighlighted: isHighlighted,
                renameAction: { onRenameHostname(member) },
                configureAction: member.isLocal ? onConfigureLocalMember : nil
            )
        case .publicServerGroup(let group):
            PublicServerGroupIdentity(group: group, isHighlighted: isHighlighted)
        }
    }
}

private struct MemberStatusIdentity: View {
    var member: NetworkMemberStatus
    var isHighlighted: Bool
    var renameAction: (() -> Void)? = nil
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
            .contextMenu { memberContextMenu }
        } else if renameAction != nil {
            identityContent
                .padding(.vertical, 5)
                .contextMenu { memberContextMenu }
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
                Text(memberSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .memberIdentityHighlight(isHighlighted: isHighlighted)
    }

    @ViewBuilder
    private var memberContextMenu: some View {
        if !member.peerID.isEmpty, member.peerID != "-" {
            Button("Copy Peer ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(member.peerID, forType: .string)
            }
        }
        if let renameAction {
            Button("Rename Hostname...") {
                renameAction()
            }
        }
        if let configureAction {
            Button("Open Config") {
                configureAction()
            }
        }
    }

    private var memberSubtitle: String {
        [member.memberStateLabel, member.peerIDLabel].compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != "-" }
            .joined(separator: " · ")
    }
}

private extension View {
    func trackScrollPhase(isScrolling: Binding<Bool>) -> some View {
        onScrollPhaseChange { _, phase in
            isScrolling.wrappedValue = phase.isScrolling
        }
    }

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

private extension View {
    func memberIdentityHighlight(isHighlighted: Bool) -> some View {
        modifier(MemberIdentityHighlight(isHighlighted: isHighlighted))
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
    var animates = true

    private var quality: LatencyQuality {
        LatencyQuality(value)
    }

    var body: some View {
        AnimatedMetricText(
            value: value,
            color: quality.color,
            fontWeight: .regular,
            animates: animates
        )
        .help(quality.helpText(for: value))
    }
}

private struct AnimatedMetricText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        animates && !reduceMotion
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

    static func width(for value: String) -> CGFloat {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let measuredTextWidth = textWidth(for: text.isEmpty ? "255.255.255.255" : text)
        let targetWidth = measuredTextWidth + horizontalPadding * 2 + trailingReservation
        return max(ceil(targetWidth), 120)
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
                isHovering = hovering
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
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                ConnectionGlyph(state: state, size: 46)
            }
        } description: {
            description
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
                .foregroundStyle(.secondary)
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
        .liquidGlassMetricBackground(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

private struct RuntimeIntentConflictBanner: View {
    var intent: RuntimeIntent
    var useRemoteAction: () -> Void
    var reapplyAction: () -> Void
    var keepPendingAction: () -> Void

    private var title: String {
        switch intent.kind {
        case .hostname:
            "Hostname change conflict"
        case .portForwardSet:
            "Port forwarding change conflict"
        }
    }

    private var detail: String {
        let target = intent.target.recentHostname ?? intent.target.instanceID ?? intent.target.peerID ?? intent.target.networkName
        let desired = intent.desired.hostname ?? "saved value"
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
