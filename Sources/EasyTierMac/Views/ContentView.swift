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
    @State private var draftConfig = NetworkConfig()
    @State private var draftConfigID: String?
    @State private var draftIsDirty = false
    @State private var workspaceTransitionEdge: Edge = .trailing
    @State private var workspaceTransitionDistance: CGFloat = Self.tabTransitionDistance

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
                initialText: tomlMode == .export ? store.exportSelectedTOML() : ""
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
            StatusView {
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

        return List(selection: selectedConfigIDBinding) {
            Section("Networks") {
                ForEach(store.configs) { stored in
                    NetworkRow(stored: stored, state: connectionState(for: stored))
                        .tag(stored.id as String?)
                }
            }
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
                    tomlMode = .import
                    showingTOML = true
                }
                Button("Export TOML") {
                    commitDraft(saveImmediately: true)
                    tomlMode = .export
                    showingTOML = true
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

    private var selectedConfigIDBinding: Binding<String?> {
        Binding(
            get: { store.selectedConfigID },
            set: { newValue in
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
