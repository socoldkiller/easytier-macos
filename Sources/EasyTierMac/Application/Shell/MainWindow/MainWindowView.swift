@preconcurrency import AppKit
import EasyTierShared
import SwiftUI

struct MainWindowView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppContext.self) private var appContext
    @State private var tomlPresentation: TOMLPresentation?
    @State private var draftConfig = NetworkConfig()
    @State private var draftNetworkSecret: NetworkSecretInput?
    @State private var draftConfigID: String?
    @State private var draftIsDirty = false
    @State private var configApplyCoordinator = ConfigApplyCoordinator()
    @State private var workspaceTransitionEdge: Edge = .trailing
    @State private var workspaceTransitionDistance: CGFloat = Self.tabTransitionDistance
    @State private var networkSearchText = ""
    @State private var highlightedSearchPeerID: String?
    @State private var highlightToken = 0
    @State private var selectedSearchResultID: String?
    @State private var selectedTabLocal: WorkspaceTab = .status
    @State private var selectedConfigIDLocal: String?
    @State private var showingDeleteRunningNetworkConfirmation = false
    @State private var configEditorScrolledPastTop = false

    private static let tabTransitionDistance: CGFloat = 14
    private static let networkTransitionDistance: CGFloat = 7
    private static let remoteRenameConfirmationAttempts = 12
    private static let sidebarTopClearance: CGFloat = 8

    private var store: EasyTierAppStore { appContext.workspace.store }
    private var appearanceSettings: AppAppearanceSettings { appContext.settings.appearance }

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
            MotionSwitch(
                id: workspaceMotionID,
                insertionEdge: workspaceTransitionEdge,
                distance: workspaceTransitionDistance
            ) {
                workspaceContent
            }
        }
            .navigationTitle("")
            .toolbar { toolbar }
        }
        .overlay(alignment: .top) {
            if let notice = store.networkSecretCleanupNotice {
                NetworkSecretCleanupBanner(
                    message: notice,
                    dismiss: store.dismissNetworkSecretCleanupNotice
                )
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task(id: store.selectedConfigID) {
            loadDraft(for: store.selectedConfigID)
        }
        .task {
            selectedTabLocal = store.selectedTab
            selectedConfigIDLocal = store.selectedConfigID
        }
        .onChange(of: store.selectedTab) { _, newTab in
            selectedTabLocal = newTab
            if newTab != .config, store.remoteConfigSession != nil {
                store.clearRemoteConfigSession()
            }
        }
        .onChange(of: store.selectedConfigID) { _, newID in
            if selectedConfigIDLocal != newID {
                selectedConfigIDLocal = newID
            }
        }
        .onChange(of: store.networkSecretSessionRevision) { _, _ in
            draftNetworkSecret = draftNetworkSecret?.clearingSavedMaterial
            if tomlPresentation?.mode == .export {
                tomlPresentation = nil
            }
        }
        .onChange(of: selectedConfigIDLocal) { _, newID in
            selectConfig(id: newID)
        }
        .onChange(of: selectedTabLocal) { _, newTab in
            selectWorkspaceTab(newTab)
        }
        .onChange(of: store.pendingPeerCardMerge) { _, card in
            handlePendingPeerCardMerge(card)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await appContext.resumeRuntimeServiceIfApproved()
                }
            }
            if SensitivePresentationLifecyclePolicy.shouldClearMaterial(for: phase) {
                draftNetworkSecret = draftNetworkSecret?.clearingSavedMaterial
                if tomlPresentation?.mode == .export {
                    tomlPresentation = nil
                }
            }
        }
        .onChange(of: store.isShowingSettings) { _, isShowing in
            if isShowing {
                openSettings(tab: .general)
                store.isShowingSettings = false
            }
        }
        .onChange(of: store.isShowingAbout) { _, isShowing in
            if isShowing {
                openSettings(tab: .about)
                store.isShowingAbout = false
            }
        }
        .sheet(item: $tomlPresentation) { presentation in
            TOMLSheet(
                mode: presentation.mode,
                initialText: presentation.text,
                onImport: { text in
                    if presentation.mode == .import {
                        Task { await store.importTOML(text) }
                    }
                },
                onExportSecretInclusionChange: { includeNetworkSecret in
                    try await store.exportSelectedTOML(
                        options: TOMLExportOptions(
                            includeNetworkSecret: includeNetworkSecret
                        ),
                        networkSecretInput: draftNetworkSecret
                    )
                }
            )
        }
        .sheet(isPresented: $store.isShowingLinuxInstallGuide) {
            LinuxInstallGuideView()
        }
        .alert(
            "EasyTier",
            isPresented: Binding(
                get: { store.lastError != nil && !store.lastErrorIsHelperPermission },
                set: { if !$0 { store.lastError = nil } })
        ) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .alert(
            "EasyTier Needs Background Permission",
            isPresented: Binding(
                get: { store.lastError != nil && store.lastErrorIsHelperPermission },
                set: { if !$0 { store.lastError = nil } })
        ) {
            if store.helperRegistration?.state == .requiresApproval {
                Button("Open System Settings") {
                    store.lastError = nil
                    store.helperRegistration?.openSystemSettings()
                }
            } else {
                Button("Install Helper") {
                    Task {
                        store.lastError = nil
                        await appContext.prepareRuntimeService()
                    }
                }
            }
            Button("Cancel", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .alert("Delete Running Network?", isPresented: $showingDeleteRunningNetworkConfirmation) {
            Button("Delete", role: .destructive) {
                deleteSelectedConfig()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(deleteConfirmationNetworkName) is running. Deleting it will stop the network first.")
        }
        .onDisappear {
            flushPendingLocalDraft()
            draftNetworkSecret = draftNetworkSecret?.clearingSavedMaterial
            store.lockNetworkSecretSession()
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch store.selectedTab {
        case .status:
            StatusView(
                highlightedMemberPeerID: highlightedSearchPeerID,
                onRenameLocalHostname: renameSelectedHostname,
                onRenameRemoteHostname: renameRemoteHostname,
                onConfigureLocalMember: { selectWorkspaceTab(.config) },
                onConfigureRemoteMember: configureRemoteMember
            )
        case .view:
            TrafficView()
        case .config:
            if let session = store.remoteConfigSession {
                remoteConfigContent(session: session)
            } else if let config = draftConfigBinding() {
                ConfigEditorView(
                    config: config,
                    networkSecretDraft: $draftNetworkSecret,
                    members: store.selectedLiveMemberStatuses
                )
            } else if store.selectedConfigID != nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Network",
                    systemImage: "slider.horizontal.3",
                    description: Text("Create a network config to begin.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .logs:
            LogsView()
        case .peers:
            PeersView()
        }
    }

    private var toolbarControlsHidden: Bool {
        store.selectedTab == .config && configEditorScrolledPastTop
    }

    private var remoteToolbarSession: RemoteConfigSession? {
        guard store.selectedTab == .config else { return nil }
        return store.remoteConfigSession
    }

    private var sidebar: some View {

        return Group {
            if networkSearchQuery.isEmpty {
                List(selection: $selectedConfigIDLocal) {
                    Section {
                        ForEach(store.configs) { stored in
                            NetworkRow(stored: stored, state: connectionState(for: stored))
                                .tag(stored.id as String?)
                        }
                    } header: {
                        Color.clear
                            .frame(height: Self.sidebarTopClearance)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .accessibilityHidden(true)
                    }
                }
                .scrollContentBackground(.hidden)
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
                .scrollContentBackground(.hidden)
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
        .onChange(of: networkSearchQuery.isEmpty ? [] : networkSearchResultIDs) { _, ids in
            reconcileSearchSelection(with: ids)
        }
        .easyTierSidebarBackground(
            glassEffectsEnabled: appearanceSettings.glassEffectsEnabled,
            renderCoordinator: appContext.presentation.glassRenderCoordinator
        )
        .background {
            SearchKeyboardBridge(
                isActive: !networkSearchQuery.isEmpty,
                onUp: { moveSelectedSearchResult(by: -1) },
                onDown: { moveSelectedSearchResult(by: 1) },
                onReturn: openSelectedSearchResult
            )
        }
        .scrollIndicators(.hidden, axes: [.vertical, .horizontal])
        .hideScrollViewScrollers()
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    flushPendingLocalDraft()
                    store.addConfig()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add network")
                .accessibilityLabel(Text("Add network"))
                Button(role: .destructive) {
                    requestDeleteSelectedConfig()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete selected network")
                .accessibilityLabel(Text("Delete selected network"))
                .disabled(store.selectedConfigID == nil || store.isBusy || store.isQuitting)
                Spacer()
                Button {
                    Task { await store.refreshRuntime() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh runtime state")
                .accessibilityLabel(Text("Refresh runtime state"))
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            WorkspaceTabPicker(selection: $selectedTabLocal)
                .toolbarAutoHidden(toolbarControlsHidden, reduceMotion: reduceMotion)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if let remoteSession = remoteToolbarSession {
                Button {
                    Task { await applyRemoteToolbarChanges() }
                } label: {
                    remoteApplyButtonLabel(for: remoteSession)
                }
                .disabled(remoteApplyButtonIsDisabled(for: remoteSession))
                .help(remoteApplyButtonHelp(for: remoteSession))
                .toolbarAutoHidden(toolbarControlsHidden, reduceMotion: reduceMotion)
            } else {
                localConfigApplyStatus

                Button {
                    openSettings(tab: .general)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("EasyTier Settings")
                .toolbarAutoHidden(toolbarControlsHidden, reduceMotion: reduceMotion)

                Button {
                    performSelectedConnectionAction()
                } label: {
                    Label(
                        connectionActionTitle,
                        systemImage: connectionActionSystemImage
                    )
                }
                .disabled(store.selectedConfig == nil || store.isBusy)
                .help(connectionActionHelp)
                .toolbarAutoHidden(toolbarControlsHidden, reduceMotion: reduceMotion)
            }

            Menu {
                if let remoteSession = remoteToolbarSession {
                    Button("Restart \(remoteSession.member.hostname)") {
                        Task { await store.applyRemoteConfigChanges(forceRestart: true) }
                    }
                    .disabled(
                        remoteSession.isLoading
                            || remoteSession.loadError != nil
                            || remoteSession.applyState.isApplying
                            || store.isBusy
                    )
                } else {
                    Button("Restart Network") {
                        restartSelectedNetworkManually()
                    }
                    .disabled(!selectedConfigCanStop || store.isBusy)

                    Divider()

                    Button("Import TOML") {
                        flushPendingLocalDraft()
                        openImportTOML()
                    }
                    Button("Export TOML") {
                        Task {
                            await configApplyCoordinator.flush()
                            await openExportTOML()
                        }
                    }
                    .disabled(store.selectedConfig == nil)
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .toolbarAutoHidden(toolbarControlsHidden, reduceMotion: reduceMotion)

            Menu {
                Button("Install on Linux") {
                    store.isShowingLinuxInstallGuide = true
                }
                Link("Online Docs", destination: URL(string: "https://easytier.cn") ?? URL(fileURLWithPath: "/"))
                Link("Releases", destination: URL(string: "https://github.com/EasyTier/EasyTier/releases") ?? URL(fileURLWithPath: "/"))
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .toolbarAutoHidden(toolbarControlsHidden, reduceMotion: reduceMotion)

            Button {
                store.isShowingAbout = true
            } label: {
                Label("About", systemImage: "info.circle")
            }
            .help("About EasyTier")
            .toolbarAutoHidden(toolbarControlsHidden, reduceMotion: reduceMotion)
        }
    }

    @ViewBuilder
    private var localConfigApplyStatus: some View {
        if store.selectedTab == .config,
           configApplyCoordinator.targetConfigID == draftConfigID
        {
            switch configApplyCoordinator.phase {
            case .idle:
                EmptyView()
            case .pending:
                Label("Changes Pending", systemImage: "clock")
                    .help("Configuration changes will be applied automatically")
                    .toolbarAutoHidden(toolbarControlsHidden, reduceMotion: reduceMotion)
            case .applying:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Applying Changes")
                }
                .help("Saving configuration and reconnecting the network")
                .toolbarAutoHidden(toolbarControlsHidden, reduceMotion: reduceMotion)
            case .applied:
                Label("Changes Applied", systemImage: "checkmark.circle.fill")
                    .help("Configuration changes are active")
                    .toolbarAutoHidden(toolbarControlsHidden, reduceMotion: reduceMotion)
            case let .failed(message):
                Button {
                    Task { await configApplyCoordinator.retry() }
                } label: {
                    Label("Retry Changes", systemImage: "exclamationmark.triangle.fill")
                }
                .help(message)
                .toolbarAutoHidden(toolbarControlsHidden, reduceMotion: reduceMotion)
            }
        }
    }

    private var selectedConfigCanStop: Bool {
        store.selectedConfigCanStop
    }

    private var selectedConfigIsReady: Bool {
        selectedConfigCanStop && store.selectedRuntimeReadinessPhase == .ready
    }

    private var deleteConfirmationNetworkName: String {
        store.selectedConfig?.network_name.nilIfEmpty ?? "The selected network"
    }

    private var selectedConfigHasRuntimeError: Bool {
        guard var instance = store.selectedRunningInstance else { return false }
        instance.detail = store.selectedRuntimeDetail
        return instance.runtimeErrorMessage != nil || instance.listenerErrorFromEvents != nil
    }

    private var workspaceMotionID: String {
        if let session = store.remoteConfigSession {
            return "\(store.selectedTab.id)-remote-\(session.member.id)"
        }
        return "\(store.selectedTab.id)-\(store.selectedConfigID ?? "none")"
    }

    private var connectionActionTitle: String {
        if store.isBusy { return "Working" }
        if selectedConfigHasRuntimeError { return "Stop" }
        if selectedConfigCanStop { return selectedConfigIsReady ? "Pause" : "Stop" }
        return "Run"
    }

    private var connectionActionSystemImage: String {
        if store.isBusy { return "hourglass" }
        if selectedConfigHasRuntimeError { return "stop.fill" }
        if selectedConfigCanStop { return selectedConfigIsReady ? "pause.fill" : "stop.fill" }
        return "play.fill"
    }

    private var connectionActionHelp: String {
        if store.isBusy { return "Working" }
        if selectedConfigHasRuntimeError { return "Stop selected network" }
        if selectedConfigIsReady { return "Pause selected network" }
        if selectedConfigCanStop { return "Stop selected network while it is starting" }
        return "Run selected network"
    }

    private func applyRemoteToolbarChanges() async {
        guard let session = store.remoteConfigSession else { return }
        let retryingManualRestart: Bool
        if case .failed = session.applyState {
            retryingManualRestart = !session.hasUnsavedChanges
        } else {
            retryingManualRestart = false
        }
        _ = await store.applyRemoteConfigChanges(forceRestart: retryingManualRestart)
    }

    @ViewBuilder
    private func remoteApplyButtonLabel(for session: RemoteConfigSession) -> some View {
        switch session.applyState {
        case .idle:
            Label("Apply Changes", systemImage: "gearshape")
        case .applying:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Applying Changes")
            }
        case .applied:
            Label("Changes Applied", systemImage: "checkmark.circle.fill")
        case .failed:
            Label(
                session.hasUnsavedChanges ? "Retry Changes" : "Retry Restart",
                systemImage: "exclamationmark.triangle.fill"
            )
        }
    }

    private func remoteApplyButtonIsDisabled(for session: RemoteConfigSession) -> Bool {
        if session.isLoading || session.loadError != nil || session.applyState.isApplying || store.isBusy {
            return true
        }
        if case .failed = session.applyState {
            return false
        }
        return !session.hasUnsavedChanges
    }

    private func remoteApplyButtonHelp(for session: RemoteConfigSession) -> String {
        switch session.applyState {
        case .idle:
            session.hasUnsavedChanges
                ? "Apply changes and restart \(session.member.hostname)"
                : "No pending remote changes"
        case .applying:
            "Applying changes and restarting \(session.member.hostname)"
        case .applied:
            "Changes applied to \(session.member.hostname)"
        case let .failed(message):
            message
        }
    }

    private func connectionState(for config: NetworkConfig) -> ConnectionGlyphState {
        if store.lastError != nil, store.selectedConfigID == config.id { return .error }
        if store.isBusy, store.selectedConfigID == config.id { return .connecting }
        switch store.runtimeReadinessPhase(matching: config) {
        case .stopped:
            return .idle
        case .starting:
            return .connecting
        case .ready:
            guard let instance = store.runningInstance(matching: config) else { return .idle }
            return store.instanceIsFullyConnected(instance) ? .connected : .connecting
        case .failed:
            return .error
        }
    }

    private var networkSearchQuery: SearchQuery {
        SearchQuery(networkSearchText)
    }

    private var networkSearchResults: [NetworkSearchResult] {
        NetworkSearchIndex.results(
            matching: networkSearchQuery,
            configs: store.configs,
            instanceForConfig: store.runningInstance(matching:),
            connectionStateForConfig: connectionState(for:)
        )
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

    private func openSettings(tab: EasyTierSettingsTab) {
        appContext.settings.request(tab)
        openWindow(id: EasyTierWindowID.settings)
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

        if store.remoteConfigSession != nil {
            store.clearRemoteConfigSession()
        }
        flushPendingLocalDraft()
        EasyTierPerformanceSignposts.workspaceTransition()
        workspaceTransitionEdge = networkTransitionEdge(from: previousValue, to: newValue)
        workspaceTransitionDistance = Self.networkTransitionDistance
        store.selectedConfigID = newValue
        loadDraft(for: newValue)
    }

    private func selectWorkspaceTab(_ tab: WorkspaceTab) {
        guard tab != store.selectedTab else { return }
        flushPendingLocalDraft()
        EasyTierPerformanceSignposts.workspaceTransition()
        workspaceTransitionEdge =
            tab.motionIndex > store.selectedTab.motionIndex ? .trailing : .leading
        workspaceTransitionDistance = Self.tabTransitionDistance
        store.selectedTab = tab
    }

    private func handlePendingPeerCardMerge(_ card: PeerCard?) {
        guard let card else { return }
        defer { store.pendingPeerCardMerge = nil }

        guard let selectedID = store.selectedConfigID,
              draftConfigID == selectedID
        else { return }

        let existing = Set(draftConfig.peer_urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let toAdd = card.urls.filter { !existing.contains($0) }
        guard !toAdd.isEmpty else { return }

        draftConfig.peer_urls.append(contentsOf: toAdd)
        draftIsDirty = true
        scheduleLocalConfigApply()

        selectWorkspaceTab(.config)
    }

    private func requestDeleteSelectedConfig() {
        if selectedConfigCanStop {
            showingDeleteRunningNetworkConfirmation = true
        } else {
            deleteSelectedConfig()
        }
    }

    private func deleteSelectedConfig() {
        configApplyCoordinator.cancelPending()
        draftIsDirty = false
        Task { await store.deleteSelectedConfig() }
    }

    private func configureRemoteMember(_ member: NetworkMemberStatus) {
        store.clearRemoteConfigSession()
        selectWorkspaceTab(.config)
        Task {
            await store.startRemoteConfigSession(member: member)
        }
    }

    private func remoteConfigBinding() -> Binding<NetworkConfig>? {
        guard store.remoteConfigSession != nil else { return nil }
        return Binding(
            get: { store.remoteConfigSession?.config ?? NetworkConfig() },
            set: { newValue in
                store.remoteConfigSession?.config = newValue
            }
        )
    }

    @ViewBuilder
    private func remoteConfigContent(session: RemoteConfigSession) -> some View {
        if session.isLoading {
            ProgressView("Loading \(session.member.hostname) configuration...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = session.loadError {
            VStack(spacing: 16) {
                ContentUnavailableView(
                    "RPC Unavailable",
                    systemImage: "wifi.exclamationmark",
                    description: Text("\(error)\n\nMake sure RPC is enabled on \(session.member.hostname) (port \(AppMode.defaultRPCListenPort)) and that your IP is allowed.")
                )
                Button("Back to Status") {
                    store.clearRemoteConfigSession()
                    selectWorkspaceTab(.status)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let config = remoteConfigBinding() {
            ConfigEditorView(config: config, members: store.selectedLiveMemberStatuses, remoteSession: session)
                .disabled(session.applyState.isApplying)
        }
    }

    private func renameSelectedHostname(_ hostname: String) {
        guard let selectedID = store.selectedConfigID,
            let storedConfig = store.configs.first(where: { $0.id == selectedID })
        else { return }

        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let newHostname = trimmed.isEmpty ? nil : trimmed
        let previousHostname = storedConfig.hostname?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let runningInstanceToPatch = draftIsDirty ? nil : store.runningInstance(matching: storedConfig)
        if previousHostname == newHostname {
            guard newHostname == nil, runningInstanceToPatch != nil else { return }
        }

        var updatedConfig = storedConfig
        updatedConfig.hostname = newHostname
        Task {
            do {
                try await store.updateConfig(
                    id: selectedID,
                    with: updatedConfig,
                    saveImmediately: true
                )
            } catch {
                store.lastError = error.localizedDescription
                return
            }

            if draftConfigID == selectedID {
                if draftIsDirty {
                    draftConfig.hostname = newHostname
                } else {
                    draftConfig = updatedConfig
                }
            }

            guard let runningInstanceToPatch else { return }
            guard let newHostname else {
                store.recordNotice("Saved hostname change. Clearing the running hostname will take effect after a manual restart.")
                return
            }
            await store.applyLocalHostnameRuntimeIntent(
                configID: selectedID,
                runningInstance: runningInstanceToPatch,
                desiredHostname: newHostname,
                baseHostname: runningInstanceToPatch.detail?.my_node_info?.hostname
            )
        }
    }

    private func renameRemoteHostname(_ member: NetworkMemberStatus, hostname: String) async -> Bool {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            store.lastError = "Remote hostname cannot be empty."
            return false
        }
        guard trimmed != member.hostname else { return true }
        guard let instanceID = member.instanceID else {
            store.lastError = "Remote instance ID is unavailable for \(member.hostname)."
            return false
        }
        guard let ip = member.copyableIPv4Address,
              let rpcURL = URL(string: "tcp://\(ip):\(AppMode.defaultRPCListenPort)") else {
            store.lastError = "Remote RPC URL is unavailable for \(member.hostname)."
            return false
        }
        let networkName = store.selectedRunningInstance?.name ?? store.selectedConfig?.network_name ?? ""
        let intent = store.upsertRemoteHostnameRuntimeIntent(
            networkName: networkName,
            member: member,
            desiredHostname: trimmed
        )

        do {
            try await EasyTierRemoteRPCClient(rpcURL: rpcURL).patchHostname(instanceID: instanceID, hostname: trimmed)
        } catch {
            store.markRuntimeIntent(intent.id, status: .unreachable)
            store.lastError = error.localizedDescription
            return false
        }

        if await waitForRemoteInstance(instanceID: instanceID, matches: { $0.hostname == trimmed }) {
            store.markRuntimeIntent(intent.id, status: .applied)
            return true
        }

        let message = "Remote hostname change was sent but not confirmed yet. Runtime status may not have refreshed."
        store.recordNotice(message)
        store.lastError = message
        return true
    }

    private func waitForRemoteInstance(instanceID: String, matches: (NetworkMemberStatus) -> Bool) async -> Bool {
        for attempt in 0..<Self.remoteRenameConfirmationAttempts {
            await store.refreshRuntime()
            if store.selectedLiveMemberStatuses.contains(where: { $0.instanceID == instanceID && matches($0) }) {
                return true
            }
            if attempt + 1 < Self.remoteRenameConfirmationAttempts {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return false
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
                guard newValue != draftConfig else { return }
                draftConfig = newValue
                draftIsDirty = true
                scheduleLocalConfigApply()
            }
        )
    }

    private func scheduleLocalConfigApply() {
        guard draftIsDirty, let draftConfigID else { return }
        let storedConfig = store.configs.first(where: { $0.id == draftConfigID })
        let runningInstance = storedConfig.flatMap(store.runningInstance(matching:))
        let request = LocalConfigApplyRequest(
            configID: draftConfigID,
            config: currentLocalDraft(),
            replacing: runningInstance
        )
        configApplyCoordinator.schedule(request) { request in
            await applyLocalConfigRequest(request)
        }
    }

    private func applyLocalConfigRequest(_ request: LocalConfigApplyRequest) async -> ConfigApplyResult {
        let result = await store.applyConfigDraft(
            configID: request.configID,
            draft: request.config,
            replacing: request.replacing
        )
        if result.succeeded,
           draftConfigID == request.configID,
           currentLocalDraft() == request.config
        {
            draftIsDirty = false
        }
        return result
    }

    private func flushPendingLocalDraft() {
        guard draftIsDirty else { return }
        scheduleLocalConfigApply()
        Task { await configApplyCoordinator.flush() }
    }

    private func performSelectedConnectionAction() {
        let shouldStop = selectedConfigCanStop
        let pendingDraft: LocalConfigApplyRequest?
        if draftIsDirty, let draftConfigID {
            pendingDraft = LocalConfigApplyRequest(
                configID: draftConfigID,
                config: currentLocalDraft(),
                replacing: nil
            )
        } else {
            pendingDraft = nil
        }
        let networkSecretInput = draftNetworkSecret
        let networkSecretSessionRevision = store.networkSecretSessionRevision
        configApplyCoordinator.cancelPending()
        if pendingDraft != nil {
            draftIsDirty = false
        }

        Task {
            if shouldStop {
                await store.stopSelectedConfig()
                if let pendingDraft {
                    _ = await store.applyConfigDraft(
                        configID: pendingDraft.configID,
                        draft: pendingDraft.config,
                        replacing: nil
                    )
                }
            } else {
                if let pendingDraft {
                    let result = await store.applyConfigDraft(
                        configID: pendingDraft.configID,
                        draft: pendingDraft.config,
                        replacing: nil
                    )
                    guard result.succeeded else {
                        if draftConfigID == pendingDraft.configID,
                           currentLocalDraft() == pendingDraft.config
                        {
                            draftIsDirty = true
                        }
                        if case let .failed(message) = result { store.lastError = message }
                        return
                    }
                }
                let outcome = await store.runSelectedConfig(
                    networkSecretInput: networkSecretInput
                )
                markNetworkSecretPersisted(
                    networkSecretInput,
                    outcome: outcome,
                    sessionRevision: networkSecretSessionRevision
                )
            }
        }
    }

    private func restartSelectedNetworkManually() {
        guard let config = store.selectedConfig,
              let instance = store.runningInstance(matching: config)
        else { return }
        let pendingDraft = draftIsDirty ? LocalConfigApplyRequest(
            configID: config.id,
            config: currentLocalDraft(),
            replacing: nil
        ) : nil
        let networkSecretInput = draftNetworkSecret
        let networkSecretSessionRevision = store.networkSecretSessionRevision
        configApplyCoordinator.cancelPending()
        if pendingDraft != nil {
            draftIsDirty = false
        }
        Task {
            if let pendingDraft {
                let result = await store.applyConfigDraft(
                    configID: pendingDraft.configID,
                    draft: pendingDraft.config,
                    replacing: nil
                )
                guard result.succeeded else {
                    if draftConfigID == pendingDraft.configID,
                       currentLocalDraft() == pendingDraft.config
                    {
                        draftIsDirty = true
                    }
                    if case let .failed(message) = result { store.lastError = message }
                    return
                }
            }
            let outcome = await store.restartSelectedConfig(
                replacing: instance,
                configID: config.id,
                networkSecretInput: networkSecretInput
            )
            markNetworkSecretPersisted(
                networkSecretInput,
                outcome: outcome,
                sessionRevision: networkSecretSessionRevision
            )
        }
    }

    private func loadDraft(for selectedID: String?) {
        guard let selectedID,
            let config = store.configs.first(where: { $0.id == selectedID })
        else {
            draftConfig = NetworkConfig()
            draftNetworkSecret = nil
            draftConfigID = nil
            draftIsDirty = false
            return
        }
        guard draftConfigID != selectedID else { return }
        draftConfig = config
        draftNetworkSecret = nil
        draftConfigID = selectedID
        draftIsDirty = false
    }

    private func currentLocalDraft() -> NetworkConfig {
        var config = draftConfig
        config.network_secret = nil
        return config
    }

    private func markNetworkSecretPersisted(
        _ input: NetworkSecretInput?,
        outcome: NetworkSecretOperationOutcome,
        sessionRevision: UInt64
    ) {
        guard outcome.didPersistEditedSecret,
              store.networkSecretSessionRevision == sessionRevision,
              !SensitivePresentationLifecyclePolicy.shouldClearMaterial(for: scenePhase),
              draftNetworkSecret == input,
              let input
        else { return }
        draftNetworkSecret = input.applying(outcome)
    }

    private func openImportTOML() {
        tomlPresentation = TOMLPresentation(mode: .import, text: "")
    }

    private func openExportTOML() async {
        do {
            tomlPresentation = TOMLPresentation(
                mode: .export,
                text: try await store.exportSelectedTOML(
                    networkSecretInput: draftNetworkSecret
                )
            )
        } catch {
            if !EasyTierAppStore.isNetworkSecretAccessCancellation(error) {
                store.lastError = error.localizedDescription
            }
        }
    }
}

private struct NetworkSecretCleanupBanner: View {
    var message: String
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.horizontal.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Keychain cleanup notice")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        .padding(.horizontal, 18)
    }
}
