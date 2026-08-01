@preconcurrency import AppKit
import EasyTierShared
import SwiftUI

struct MainWindowView: View {
    @Environment(\.openWindow) var openWindow
    @Environment(\.openSettings) var openSettingsAction
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(AppContext.self) var appContext
    @State var tomlPresentation: TOMLPresentation?
    @State var draftConfig = NetworkConfig()
    @State var draftNetworkSecret: NetworkSecretInput?
    @State var draftConfigID: String?
    @State var draftIsDirty = false
    @State var configTextFieldIsEditing = false
    @State var configApplyCoordinator = ConfigApplyCoordinator()
    @State var workspaceTransitionEdge: Edge = .trailing
    @State var workspaceTransitionDistance: CGFloat = Self.tabTransitionDistance
    @State var networkSearchText = ""
    @State var highlightedSearchPeerID: String?
    @State var highlightToken = 0
    @State var selectedSearchResultID: String?
    @State var selectedTabLocal: WorkspaceTab = .status
    @State var selectedConfigIDLocal: String?
    @State var showingDeleteRunningNetworkConfirmation = false
    @State var configEditorScrolledPastTop = false
    @State var configEditorTitlebarScrollEdgeVisible = false
    @State var publishServiceRequest: PublishServiceRequest?
    @State var isChangingGateway = false
    @State var gatewayControlError: String?

    static let tabTransitionDistance: CGFloat = 14
    static let networkTransitionDistance: CGFloat = 7
    static let remoteRenameConfirmationAttempts = 12
    static let sidebarTopClearance: CGFloat = 8

    var store: EasyTierAppStore { appContext.workspace.store }
    var gateway: GatewayRuntimeController { appContext.runtime.gateway }
    var appearanceSettings: AppAppearanceSettings { appContext.settings.appearance }
    var allowedWorkspaceTabs: [WorkspaceTab] {
        WorkspaceTab.displayOrder.filter { $0 != .services || appContext.runtime.gateway.servicesVisible }
    }

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if case let .unavailable(failure) = store.persistenceHealth {
                    PersistenceRecoveryView(failure: failure)
                }
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
        .easyTierTitlebarScrollEdgeBackground(
            isVisible: configEditorTitlebarScrollEdgeVisible,
            glassEffectsEnabled: appearanceSettings.glassEffectsEnabled && !reduceTransparency
        )
        .task(id: store.selectedConfigID) {
            loadDraft(for: store.selectedConfigID)
        }
        .task {
            selectedTabLocal = store.selectedTab
            selectedConfigIDLocal = store.selectedConfigID
        }
        .onChange(of: store.selectedTab) { _, newTab in
            selectedTabLocal = newTab
            if newTab != .config {
                configEditorTitlebarScrollEdgeVisible = false
            }
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
        .onChange(of: appContext.runtime.gateway.servicesVisible) { _, isVisible in
            if !isVisible, store.selectedTab == .services {
                selectWorkspaceTab(.status)
            }
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
                openAboutWindow()
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
        .sheet(item: $publishServiceRequest) { request in
            PublishServiceSheet(preferredTargetPeerID: request.preferredTargetPeerID)
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
    var workspaceContent: some View {
        switch store.selectedTab {
        case .status:
            StatusView(
                highlightedMemberPeerID: highlightedSearchPeerID,
                onRenameLocalHostname: renameSelectedHostname,
                onRenameRemoteHostname: renameRemoteHostname,
                onConfigureLocalMember: { selectWorkspaceTab(.config) },
                onConfigureRemoteMember: configureRemoteMember,
                onPublishService: { member in
                    beginPublishingService(preferredTargetPeerID: member.peerID)
                }
            )
        case .services:
            if store.persistenceIsReady {
                ServicesView(gatewayControlError: gatewayControlError) {
                    beginPublishingService()
                }
            } else {
                persistenceUnavailableContent
            }
        case .view:
            TrafficView()
        case .config:
            if !store.persistenceIsReady {
                persistenceUnavailableContent
            } else if let session = store.remoteConfigSession {
                remoteConfigContent(session: session)
            } else if store.selectedConfigIsRuntimeManaged {
                runtimeManagedConfigContent
            } else if let config = draftConfigBinding() {
                ConfigEditorView(
                    config: config,
                    networkSecretDraft: $draftNetworkSecret,
                    members: store.selectedLiveMemberStatuses,
                    onScrolledPastTopChange: { configEditorTitlebarScrollEdgeVisible = $0 },
                    onTextEditingChange: { configTextFieldIsEditing = $0 },
                    onTextEditingCommit: scheduleLocalConfigApply
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
            if store.persistenceIsReady {
                PeersView()
            } else {
                persistenceUnavailableContent
            }
        }
    }

    @ViewBuilder
    var runtimeManagedConfigContent: some View {
        if let config = store.selectedRuntimeManagedConfiguration {
            ConfigEditorView(
                config: .constant(config),
                members: store.selectedLiveMemberStatuses,
                isReadOnly: true,
                onScrolledPastTopChange: { configEditorTitlebarScrollEdgeVisible = $0 }
            )
        } else if let error = store.selectedRuntimeManagedConfigurationLoadError {
            VStack(spacing: 16) {
                ContentUnavailableView(
                    "Configuration Unavailable",
                    systemImage: "server.rack",
                    description: Text(error)
                )
                Button("Retry") {
                    Task { await store.reloadSelectedRuntimeManagedConfiguration() }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("Loading Config Server configuration...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var persistenceUnavailableContent: some View {
        ContentUnavailableView(
            "Database Unavailable",
            systemImage: "externaldrive.badge.exclamationmark",
            description: Text("Restore database access before changing saved configuration.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var toolbarControlsHidden: Bool {
        store.selectedTab == .config && configEditorScrolledPastTop
    }

    var remoteToolbarSession: RemoteConfigSession? {
        guard store.selectedTab == .config else { return nil }
        return store.remoteConfigSession
    }
}
