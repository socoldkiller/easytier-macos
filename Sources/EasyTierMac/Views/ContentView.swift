@preconcurrency import AppKit
import EasyTierShared
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(EasyTierAppStore.self) private var store
    @State private var permissionController = PermissionController()
    @State private var showingModeSettings = false
    @State private var showingTOML = false
    @State private var tomlMode: TOMLSheet.Mode = .export
    @State private var tomlText = ""
    @State private var draftConfig = NetworkConfig()
    @State private var draftConfigID: String?
    @State private var draftIsDirty = false
    @State private var workspaceTransitionEdge: Edge = .trailing
    @State private var workspaceTransitionDistance: CGFloat = Self.tabTransitionDistance
    @State private var networkSearchText = ""
    @State private var highlightedSearchPeerID: String?
    @State private var highlightToken = 0
    @State private var selectedSearchResultID: String?

    private static let tabTransitionDistance: CGFloat = 14
    private static let networkTransitionDistance: CGFloat = 7

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                PermissionBanner(controller: permissionController)

                MotionSwitch(
                    id: workspaceMotionID,
                    insertionEdge: workspaceTransitionEdge,
                    distance: workspaceTransitionDistance
                ) {
                    workspaceContent
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar { toolbar }
        }
        .task(id: store.selectedConfigID) {
            loadDraft(for: store.selectedConfigID)
        }
        .task {
            await permissionController.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await permissionController.refresh() }
            }
        }
        .sheet(isPresented: $showingModeSettings) {
            ModeSettingsSheet(mode: store.mode) { mode in
                Task { await store.applyMode(mode) }
            }
        }
        .sheet(isPresented: $showingTOML) {
            TOMLSheet(
                mode: tomlMode,
                initialText: tomlText
            ) { text in
                if tomlMode == .import { store.importTOML(text) }
            }
        }
        .sheet(isPresented: $store.isShowingAbout) {
            AboutView()
        }
        .alert(
            "EasyTier",
            isPresented: Binding(
                get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })
        ) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .windowMotion(role: .document)
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch store.selectedTab {
        case .status:
            StatusView(highlightedMemberPeerID: highlightedSearchPeerID) {
                selectWorkspaceTab(.config)
            }
        case .view:
            TrafficView()
        case .config:
            if let config = draftConfigBinding() {
                ConfigEditorView(config: config, members: store.selectedMemberStatuses)
            } else if store.selectedConfigID != nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Network",
                    systemImage: "network",
                    description: Text("Create a network config to begin.")
                )
            }
        case .logs:
            LogsView()
        }
    }

    private var sidebar: some View {
        @Bindable var store = store

        return Group {
            if networkSearchQuery.isEmpty {
                List(selection: selectedConfigIDBinding) {
                    Section("Networks") {
                        ForEach(store.configs) { stored in
                            NetworkRow(stored: stored, state: connectionState(for: stored))
                                .tag(stored.id as String?)
                        }
                    }
                }
            } else {
                List(selection: $selectedSearchResultID) {
                    Section("Search Results") {
                        if networkSearchResults.isEmpty {
                            Label("No results", systemImage: "magnifyingglass")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(networkSearchResults) { result in
                                NetworkSearchResultRow(result: result)
                                    .contentShape(Rectangle())
                                    .tag(result.id)
                                    .onTapGesture {
                                        selectSearchResult(result)
                                    }
                            }
                        }
                    }
                }
            }
        }
        .searchable(
            text: $networkSearchText,
            placement: .sidebar,
            prompt: "Search everything"
        )
        .onChange(of: networkSearchText) { _, _ in
            selectDefaultSearchResult()
        }
        .onChange(of: networkSearchResultIDs) { _, ids in
            reconcileSearchSelection(with: ids)
        }
        .background {
            SearchKeyboardBridge(
                isActive: !networkSearchQuery.isEmpty,
                onUp: { moveSelectedSearchResult(by: -1) },
                onDown: { moveSelectedSearchResult(by: 1) },
                onReturn: openSelectedSearchResult
            )
        }
        .hiddenScrollIndicators()
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    commitDraft(saveImmediately: true)
                    store.addConfig()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add network")
                Button(role: .destructive) {
                    draftIsDirty = false
                    Task { await store.deleteSelectedConfig() }
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete selected network")
                .disabled(store.selectedConfigID == nil)
                Spacer()
                Button {
                    Task { await store.refreshRuntime() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh runtime state")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            WorkspaceTabPicker(selection: tabSelectionBinding)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showingModeSettings = true
            } label: {
                Label(store.mode.label, systemImage: "switch.2")
            }

            Button {
                let runningInstanceToRestart = draftIsDirty ? store.selectedRunningInstance : nil
                commitDraft(saveImmediately: true)
                Task {
                    await permissionController.refresh()
                    guard permissionController.state == .enabled else {
                        store.clearHelperPermissionError()
                        return
                    }
                    if let runningInstanceToRestart {
                        await store.restartSelectedConfig(replacing: runningInstanceToRestart)
                    } else if selectedConfigIsRunning {
                        await store.stopSelectedConfig()
                    } else {
                        await store.runSelectedConfig()
                    }
                }
            } label: {
                Label(
                    connectionActionTitle,
                    systemImage: connectionActionSystemImage
                )
            }
            .disabled(
                store.selectedConfig == nil || store.isBusy
                    || permissionController.state != .enabled
            )
            .help("Run selected network")

            Menu {
                Button("Import TOML") {
                    commitDraft(saveImmediately: true)
                    openImportTOML()
                }
                Button("Export TOML") {
                    commitDraft(saveImmediately: true)
                    openExportTOML()
                }
            } label: {
                Label("TOML", systemImage: "doc.text")
            }

            Button {
                store.isShowingAbout = true
            } label: {
                Label("About", systemImage: "info.circle")
            }
            .help("About EasyTier")
        }
    }

    private var navigationTitle: String {
        if draftConfigID == store.selectedConfigID {
            return draftConfig.network_name.isEmpty ? "EasyTier" : draftConfig.network_name
        }
        return store.selectedConfig?.network_name ?? "EasyTier"
    }

    private var selectedConfigIsRunning: Bool {
        if draftIsDirty, store.selectedConfigIsRunning { return true }
        guard
            let config = draftConfigID == store.selectedConfigID
                ? draftConfig : store.selectedConfig
        else { return false }
        return store.runningInstance(matching: config) != nil
    }

    private var selectedConfigNeedsRestart: Bool {
        draftIsDirty && store.selectedConfigIsRunning
    }

    private var workspaceMotionID: String {
        "\(store.selectedTab.id)-\(store.selectedConfigID ?? "none")"
    }

    private var connectionActionTitle: String {
        if store.isBusy { return "Working" }
        if selectedConfigNeedsRestart { return "Restart" }
        return selectedConfigIsRunning ? "Pause" : "Run"
    }

    private var connectionActionSystemImage: String {
        if store.isBusy { return "hourglass" }
        if selectedConfigNeedsRestart { return "arrow.clockwise" }
        return selectedConfigIsRunning ? "pause.fill" : "play.fill"
    }

    private func connectionState(for stored: StoredNetworkConfig) -> ConnectionGlyphState {
        if store.lastError != nil, store.selectedConfigID == stored.id { return .error }
        if store.isBusy, store.selectedConfigID == stored.id { return .connecting }
        if let instance = store.runningInstance(matching: stored.config) {
            return store.instanceIsFullyConnected(instance) ? .connected : .connecting
        }
        return .idle
    }

    private var networkSearchQuery: SearchQuery {
        SearchQuery(networkSearchText)
    }

    private var networkSearchResults: [NetworkSearchResult] {
        let query = networkSearchQuery
        guard !query.isEmpty else { return [] }

        return store.configs.flatMap { stored -> [NetworkSearchResult] in
            let config = stored.config
            let instance = store.runningInstance(matching: config)
            let aliases = store.deviceAliases.filter { $0.networkID == stored.id }
            var results: [NetworkSearchResult] = []

            if query.matches(networkDirectSearchFields(for: stored, instance: instance)) {
                results.append(.network(
                    id: "network-\(stored.id)",
                    networkID: stored.id,
                    title: config.network_name,
                    subtitle: networkResultSubtitle(for: stored, instance: instance),
                    state: connectionState(for: stored)
                ))
            }

            var matchedPeerIDs = Set<String>()
            for member in instance?.detail?.memberStatuses ?? [] {
                let alias = aliases.first { $0.peerID == member.peerID }
                guard query.matches(member.searchFields(alias: alias)) else { continue }

                matchedPeerIDs.insert(member.peerID)
                results.append(.device(
                    id: "device-\(stored.id)-\(member.id)",
                    networkID: stored.id,
                    title: alias?.displayName ?? member.hostname,
                    subtitle: deviceResultSubtitle(for: member, alias: alias, networkName: config.network_name),
                    systemImage: member.searchResultSystemImage,
                    targetTab: .status,
                    highlightedPeerID: member.peerID
                ))
            }

            for alias in aliases where !matchedPeerIDs.contains(alias.peerID) {
                guard query.matches([alias.displayName, alias.hostname, alias.peerID]) else { continue }
                results.append(.device(
                    id: "alias-\(stored.id)-\(alias.peerID)",
                    networkID: stored.id,
                    title: alias.displayName,
                    subtitle: "Saved alias · \(config.network_name) · \(alias.hostname) · Peer \(alias.peerID)",
                    systemImage: "tag",
                    targetTab: .status,
                    highlightedPeerID: alias.peerID
                ))
            }

            return results
        }
    }

    private var networkSearchResultIDs: [String] {
        networkSearchResults.map(\.id)
    }

    private var selectedSearchResult: NetworkSearchResult? {
        guard let selectedSearchResultID else { return nil }
        return networkSearchResults.first { $0.id == selectedSearchResultID }
    }

    private func selectDefaultSearchResult() {
        guard !networkSearchQuery.isEmpty else {
            selectedSearchResultID = nil
            return
        }
        selectedSearchResultID = networkSearchResults.first?.id
    }

    private func reconcileSearchSelection(with resultIDs: [String]) {
        guard !networkSearchQuery.isEmpty else {
            selectedSearchResultID = nil
            return
        }

        if let selectedSearchResultID, resultIDs.contains(selectedSearchResultID) { return }
        selectedSearchResultID = resultIDs.first
    }

    private func moveSelectedSearchResult(by offset: Int) {
        guard !networkSearchQuery.isEmpty else { return }
        let results = networkSearchResults
        guard !results.isEmpty else {
            selectedSearchResultID = nil
            return
        }

        let currentIndex = selectedSearchResultID.flatMap { selectedID in
            results.firstIndex { $0.id == selectedID }
        } ?? (offset > 0 ? -1 : results.count)
        let nextIndex = min(max(currentIndex + offset, 0), results.count - 1)
        selectedSearchResultID = results[nextIndex].id
    }

    private func openSelectedSearchResult() {
        guard !networkSearchQuery.isEmpty else { return }
        let result = selectedSearchResult ?? networkSearchResults.first
        guard let result else { return }
        selectSearchResult(result)
    }

    private func networkDirectSearchFields(for stored: StoredNetworkConfig, instance: NetworkInstance?) -> [String] {
        let config = stored.config
        var fields = [
            config.network_name,
            config.instance_id,
            stored.source.rawValue,
            connectionState(for: stored).searchLabel,
            instance?.name ?? "",
            instance?.instance_id ?? "",
            instance?.detail?.dev_name ?? "",
            instance?.detail?.error_msg ?? "",
        ]

        fields.append(contentsOf: [
            config.hostname ?? "",
            config.virtual_ipv4,
            String(config.network_length),
            config.public_server_url,
            config.dev_name,
            config.vpn_portal_client_network_addr,
            String(config.vpn_portal_listen_port),
            String(config.vpn_portal_client_network_len),
            String(config.socks5_port),
            config.networking_method.searchLabel,
        ])
        fields.append(contentsOf: config.peer_urls)
        fields.append(contentsOf: config.listener_urls)
        fields.append(contentsOf: config.proxy_cidrs)
        fields.append(contentsOf: config.routes)
        fields.append(contentsOf: config.exit_nodes)
        fields.append(contentsOf: config.mapped_listeners)
        fields.append(contentsOf: config.relay_network_whitelist)
        fields.append(contentsOf: config.enabledSearchFeatureLabels)
        for portForward in config.port_forwards {
            fields.append(contentsOf: [
                portForward.bind_ip,
                String(portForward.bind_port),
                portForward.dst_ip,
                String(portForward.dst_port),
                portForward.proto,
                "port forward forwarding",
            ])
        }

        return fields
    }

    private func networkResultSubtitle(for stored: StoredNetworkConfig, instance: NetworkInstance?) -> String {
        [
            stored.source.rawValue.capitalized,
            connectionState(for: stored).displayLabel,
            instance?.detail?.dev_name,
        ]
        .compactMap { $0?.nilIfEmptyForSearchResult }
        .joined(separator: " · ")
    }

    private func deviceResultSubtitle(for member: NetworkMemberStatus, alias: DeviceAlias?, networkName: String) -> String {
        var parts = ["Device", networkName]
        if let alias, alias.displayName != member.hostname {
            parts.append(member.hostname)
        }
        parts.append("Peer \(member.peerID)")
        if let ip = member.copyableIPv4Address {
            parts.append(ip)
        }
        if member.isPublicServer {
            parts.append("Public Server")
        }
        return parts.joined(separator: " · ")
    }

    private func selectSearchResult(_ result: NetworkSearchResult) {
        selectConfig(id: result.networkID)
        if let targetTab = result.targetTab {
            selectWorkspaceTab(targetTab)
        }
        if let highlightedPeerID = result.highlightedPeerID {
            highlightSearchResult(peerID: highlightedPeerID)
        }
        networkSearchText = ""
        selectedSearchResultID = nil
    }

    private func highlightSearchResult(peerID: String) {
        highlightToken += 1
        let token = highlightToken

        withAnimation(EasyTierMotion.quick(reduceMotion: reduceMotion)) {
            highlightedSearchPeerID = peerID
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard token == highlightToken else { return }
            withAnimation(EasyTierMotion.content(reduceMotion: reduceMotion)) {
                highlightedSearchPeerID = nil
            }
        }
    }

    private func selectConfig(id newValue: String?) {
        let previousValue = store.selectedConfigID
        guard newValue != previousValue else { return }

        commitDraft(saveImmediately: true)
        workspaceTransitionEdge = networkTransitionEdge(from: previousValue, to: newValue)
        workspaceTransitionDistance = Self.networkTransitionDistance
        withAnimation(EasyTierMotion.content(reduceMotion: reduceMotion)) {
            store.selectedConfigID = newValue
            loadDraft(for: newValue)
        }
    }

    private var selectedConfigIDBinding: Binding<String?> {
        Binding(
            get: { store.selectedConfigID },
            set: { newValue in
                selectConfig(id: newValue)
            }
        )
    }

    private var tabSelectionBinding: Binding<WorkspaceTab> {
        Binding(
            get: { store.selectedTab },
            set: { newValue in
                selectWorkspaceTab(newValue)
            }
        )
    }

    private func selectWorkspaceTab(_ tab: WorkspaceTab) {
        guard tab != store.selectedTab else { return }
        workspaceTransitionEdge =
            tab.motionIndex > store.selectedTab.motionIndex ? .trailing : .leading
        workspaceTransitionDistance = Self.tabTransitionDistance
        withAnimation(EasyTierMotion.selection(reduceMotion: reduceMotion)) {
            store.selectedTab = tab
        }
    }

    private func networkTransitionEdge(from oldID: String?, to newID: String?) -> Edge {
        guard
            let oldIndex = configIndex(for: oldID),
            let newIndex = configIndex(for: newID),
            oldIndex != newIndex
        else {
            return .bottom
        }

        return newIndex > oldIndex ? .bottom : .top
    }

    private func configIndex(for id: String?) -> Int? {
        guard let id else { return nil }
        return store.configs.firstIndex { $0.id == id }
    }

    private func draftConfigBinding() -> Binding<NetworkConfig>? {
        guard let selectedID = store.selectedConfigID,
            store.configs.contains(where: { $0.id == selectedID })
        else { return nil }
        guard draftConfigID == selectedID else { return nil }

        return Binding(
            get: { draftConfig },
            set: { newValue in
                draftConfig = newValue
                draftIsDirty = true
            }
        )
    }

    private func loadDraft(for selectedID: String?) {
        guard let selectedID,
            let config = store.configs.first(where: { $0.id == selectedID })?.config
        else {
            draftConfig = NetworkConfig()
            draftConfigID = nil
            draftIsDirty = false
            return
        }
        guard draftConfigID != selectedID else { return }
        draftConfig = config
        draftConfigID = selectedID
        draftIsDirty = false
    }

    private func commitDraft(saveImmediately: Bool) {
        guard draftIsDirty, let draftConfigID else {
            if saveImmediately { store.save() }
            return
        }
        store.updateConfig(id: draftConfigID, with: draftConfig, saveImmediately: saveImmediately)
        self.draftConfigID = store.selectedConfigID
        draftIsDirty = false
    }

    private func openImportTOML() {
        tomlMode = .import
        tomlText = ""
        showingTOML = true
    }

    private func openExportTOML() {
        do {
            tomlText = try store.exportSelectedTOML()
            tomlMode = .export
            showingTOML = true
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}

private struct WorkspaceTabPicker: View {
    @Binding var selection: WorkspaceTab

    private static let preferredWidth: CGFloat = 184
    private let tabs = WorkspaceTab.allCases

    var body: some View {
        Picker("View", selection: $selection) {
            ForEach(tabs) { tab in
                Label(tab.rawValue, systemImage: tab.systemImage)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.regular)
        .labelStyle(.iconOnly)
        .labelsHidden()
        .frame(width: Self.preferredWidth)
        .help("Switch workspace view")
    }
}

private struct NetworkSearchResult: Identifiable {
    var id: String
    var networkID: String
    var title: String
    var subtitle: String
    var systemImage: String
    var state: ConnectionGlyphState?
    var targetTab: WorkspaceTab?
    var highlightedPeerID: String?

    static func network(
        id: String,
        networkID: String,
        title: String,
        subtitle: String,
        state: ConnectionGlyphState
    ) -> NetworkSearchResult {
        NetworkSearchResult(
            id: id,
            networkID: networkID,
            title: title,
            subtitle: subtitle,
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
        systemImage: String,
        targetTab: WorkspaceTab,
        highlightedPeerID: String?
    ) -> NetworkSearchResult {
        NetworkSearchResult(
            id: id,
            networkID: networkID,
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            state: nil,
            targetTab: targetTab,
            highlightedPeerID: highlightedPeerID
        )
    }
}

private struct NetworkSearchResultRow: View {
    var result: NetworkSearchResult

    var body: some View {
        HStack(spacing: 10) {
            if let state = result.state {
                NetworkStatusGlyph(state: state)
            } else {
                Image(systemName: result.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SearchKeyboardBridge: NSViewRepresentable {
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

private struct PermissionBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var controller: PermissionController

    var body: some View {
        VStack(spacing: 0) {
            if controller.state != .enabled {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.title3)
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("EasyTier needs a privileged helper to create TUN devices.")
                            .font(.subheadline.weight(.semibold))
                        Text(controller.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if controller.state == .requiresApproval {
                        Button("Open Settings") { controller.openSystemSettings() }
                    }
                    switch controller.state {
                    case .requiresApproval:
                        Button("Refresh") { Task { await controller.refresh() } }
                            .disabled(controller.isBusy)
                    case .error:
                        Button("Repair Helper") { Task { await controller.repair() } }
                            .disabled(controller.isBusy)
                    default:
                        Button("Install Helper") {
                            Task { await controller.install() }
                        }
                        .disabled(controller.isBusy)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
                .transition(reduceMotion ? .opacity : .easyTierSlideFade(edge: .top, distance: 10))
                .task(id: controller.state) {
                    await refreshUntilHelperApproved()
                }
                Divider()
            }
        }
        .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: controller.state)
    }

    private func refreshUntilHelperApproved() async {
        guard controller.state == .requiresApproval else { return }

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: Self.approvalRefreshIntervalNanoseconds)
            } catch {
                return
            }
            guard controller.state == .requiresApproval else { return }
            await controller.refresh()
        }
    }

    private static let approvalRefreshIntervalNanoseconds: UInt64 = 2_000_000_000
}

extension WorkspaceTab {
    fileprivate var motionIndex: Int {
        WorkspaceTab.allCases.firstIndex(where: { $0.id == id }) ?? 0
    }

    fileprivate var systemImage: String {
        switch self {
        case .status:
            return "dot.radiowaves.left.and.right"
        case .view:
            return "chart.xyaxis.line"
        case .config:
            return "slider.horizontal.3"
        case .logs:
            return "doc.text.magnifyingglass"
        }
    }
}

private struct NetworkRow: View {
    var stored: StoredNetworkConfig
    var state: ConnectionGlyphState

    var body: some View {
        HStack(spacing: 10) {
            NetworkStatusGlyph(state: state)
            VStack(alignment: .leading, spacing: 2) {
                Text(stored.config.network_name)
                    .lineLimit(1)
                Text(stored.source.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct NetworkStatusGlyph: View {
    var state: ConnectionGlyphState

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "network")
                .font(.system(size: 16, weight: .semibold))
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
