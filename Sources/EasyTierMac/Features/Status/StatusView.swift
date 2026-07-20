import AppKit
import EasyTierShared
import SwiftUI

struct StatusView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowPresentationActivity) private var presentationActivity
    @Environment(AppContext.self) private var appContext
    @State private var publicServerGroupExpanded = false
    @State private var renameHostnameRequest: RenameHostnameRequest?
    @State private var memberSearchText = ""
    @State private var memberTableIsScrolling = false
    @State private var displayedMembers: [NetworkMemberStatus] = []

    var highlightedMemberPeerID: String? = nil
    var onRenameLocalHostname: (String) -> Void = { _ in }
    var onRenameRemoteHostname: (NetworkMemberStatus, String) async -> Bool = { _, _ in false }
    var onConfigureLocalMember: () -> Void = {}
    var onConfigureRemoteMember: (NetworkMemberStatus) -> Void = { _ in }
    var onPublishService: (NetworkMemberStatus) -> Void = { _ in }

    private var store: EasyTierAppStore { appContext.workspace.store }
    private var gateway: GatewayRuntimeController { appContext.runtime.gateway }
    private var appearanceSettings: AppAppearanceSettings { appContext.settings.appearance }
    private var snapshot: RuntimeStatusSnapshot { store.selectedStatusSnapshot }
    private var members: [NetworkMemberStatus] { snapshot.members }
    private func runtimeIntentConflict(for display: StatusDisplayModel) -> RuntimeIntent? {
        let networkName = display.instance?.name ?? store.selectedConfig?.network_name
        return store.runtimeIntents.first { intent in
            intent.status == .conflict && (networkName == nil || intent.target.networkName == networkName)
        }
    }

    var body: some View {
        @Bindable var store = self.store
        let display = statusDisplay
        VStack(alignment: .leading, spacing: 14) {
            header(display)

            if display.instance != nil, !display.members.isEmpty || !display.memberSearchQuery.isEmpty {
                WorkspaceSearchField(
                    text: $memberSearchText,
                    prompt: "Search networks, hostnames, servers, IPs, Peer IDs",
                    resultCount: display.filteredMembers.count,
                    totalCount: display.members.count
                )
            }

            if let runtimeError = display.runtimeError {
                ErrorBanner(message: runtimeError)
                    .transition(reduceMotion ? .opacity : .easyTierSlideFade(edge: .top, distance: 8))
            }

            if let conflict = runtimeIntentConflict(for: display) {
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

            MotionSwitch(id: display.contentMotionID, insertionEdge: .bottom) {
                statusContent(display)
            }
        }
        .padding()
        .animation(
            presentationActivity.allowsAnimations
                ? EasyTierMotion.content(reduceMotion: reduceMotion)
                : nil,
            value: display.runtimeError
        )
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
    private func statusContent(_ display: StatusDisplayModel) -> some View {
        if display.instance == nil {
            ConnectionEmptyState(
                "No Running Network",
                state: display.connectionState,
                description: Text("Run the selected network to see its members.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if display.members.isEmpty {
            let emptyState = emptyStateCopy(for: display.snapshot.runtimeReadinessPhase)
            ConnectionEmptyState(
                emptyState.title,
                state: display.connectionState,
                description: Text(display.runtimeError ?? emptyState.description)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !display.memberSearchQuery.isEmpty, display.filteredMembers.isEmpty {
            ContentUnavailableView(
                "No Search Results",
                systemImage: "magnifyingglass",
                description: Text("Try a network name, hostname, server role, IP address, route, NAT type, version, or Peer ID.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            memberTable(display)
        }
    }

    private func emptyStateCopy(for phase: RuntimeReadinessPhase) -> (title: String, description: String) {
        switch phase {
        case .failed:
            ("Network Failed", "EasyTier could not keep the selected network running.")
        case .starting:
            ("Starting Network", "Waiting for EasyTier to finish preparing the local network.")
        case .stopped, .ready:
            ("No Member Information", "EasyTier is running, but runtime member details have not arrived yet.")
        }
    }

    private func header(_ display: StatusDisplayModel) -> some View {
        HStack(spacing: 10) {
            StatusBadge(
                title: "Network",
                value: display.snapshot.networkName,
                systemImage: "globe"
            )
            StatusBadge(title: "Members", value: "\(display.members.count)", systemImage: "person.2.fill", width: 136)
            StatusBadge(
                title: "Device",
                value: display.snapshot.deviceName,
                systemImage: "desktopcomputer",
                width: 152
            )
            StatusBadge(title: "Mode", value: display.modeLabel, systemImage: "slider.horizontal.3")
            Spacer(minLength: 0)
        }
    }

    private func memberTable(_ display: StatusDisplayModel) -> some View {
        @Bindable var store = self.store
        return MemberGridTable(
            rowItems: display.memberRowItems,
            highlightedMemberPeerID: highlightedMemberPeerID,
            publicServerGroupExpanded: $publicServerGroupExpanded,
            isScrolling: $memberTableIsScrolling,
            globalScrolling: $store.isAnyViewScrolling,
            onRenameHostname: beginRenamingHostname,
            onConfigureLocalMember: onConfigureLocalMember,
            onConfigureRemoteMember: onConfigureRemoteMember,
            onPublishService: onPublishService
        )
    }

    private var statusDisplay: StatusDisplayModel {
        let snapshot = self.snapshot
        let members = snapshot.members
        let instance = snapshot.instance
        let runtimeError = snapshot.runtimeError
        let connectionState: ConnectionGlyphState
        if runtimeError != nil || snapshot.runtimeReadinessPhase == .failed {
            connectionState = .error
        } else if store.isBusy {
            connectionState = .connecting
        } else if instance == nil {
            connectionState = .idle
        } else {
            connectionState = snapshot.isFullyConnected ? .connected : .connecting
        }
        let tableMembers = memberTableIsScrolling && !displayedMembers.isEmpty ? displayedMembers : members
        let memberSearchQuery = SearchQuery(memberSearchText)
        var fields = [
            snapshot.networkName,
            instance?.instance_id ?? "",
            snapshot.deviceName,
            runtimeError ?? "",
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

        let filteredMembers: [NetworkMemberStatus]
        if memberSearchQuery.isEmpty || memberSearchQuery.matches(fields) {
            filteredMembers = tableMembers
        } else {
            filteredMembers = tableMembers.filter { member in
                memberSearchQuery.matches(member.searchFields)
            }
        }

        return StatusDisplayModel(
            snapshot: snapshot,
            instance: instance,
            members: members,
            runtimeError: runtimeError,
            connectionState: connectionState,
            modeLabel: store.mode.label,
            memberSearchQuery: memberSearchQuery,
            filteredMembers: filteredMembers,
            publicServerGroupExpanded: publicServerGroupExpanded
        )
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
