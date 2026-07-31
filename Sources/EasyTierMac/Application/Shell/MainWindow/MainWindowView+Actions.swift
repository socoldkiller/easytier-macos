@preconcurrency import AppKit
import EasyTierShared
import SwiftUI

extension MainWindowView {
    var networkSearchQuery: SearchQuery {
        SearchQuery(networkSearchText)
    }

    var networkSearchResults: [NetworkSearchResult] {
        NetworkSearchIndex.results(
            matching: networkSearchQuery,
            configs: store.presentedConfigs,
            instanceForConfig: store.runningInstance(matching:),
            connectionStateForConfig: connectionState(for:)
        )
    }

    var networkSearchResultIDs: [String] {
        networkSearchResults.map(\.id)
    }

    var selectedSearchResult: NetworkSearchResult? {
        guard let selectedSearchResultID else { return nil }
        return networkSearchResults.first { $0.id == selectedSearchResultID }
    }

    func selectDefaultSearchResult() {
        guard !networkSearchQuery.isEmpty else {
            selectedSearchResultID = nil
            return
        }
        selectedSearchResultID = networkSearchResults.first?.id
    }

    func reconcileSearchSelection(with resultIDs: [String]) {
        guard !networkSearchQuery.isEmpty else {
            selectedSearchResultID = nil
            return
        }

        if let selectedSearchResultID, resultIDs.contains(selectedSearchResultID) { return }
        selectedSearchResultID = resultIDs.first
    }

    func moveSelectedSearchResult(by offset: Int) {
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

    func openSelectedSearchResult() {
        guard !networkSearchQuery.isEmpty else { return }
        let result = selectedSearchResult ?? networkSearchResults.first
        guard let result else { return }
        selectSearchResult(result)
    }

    func selectSearchResult(_ result: NetworkSearchResult) {
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

    func openSettings(tab: EasyTierSettingsTab) {
        appContext.settings.request(tab)
        openSettingsAction()
    }

    func openAboutWindow() {
        openWindow(id: EasyTierWindowID.about)
    }

    func highlightSearchResult(peerID: String) {
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

    func selectConfig(id newValue: String?) {
        let previousValue = store.selectedConfigID
        guard newValue != previousValue else { return }

        if store.remoteConfigSession != nil {
            store.clearRemoteConfigSession()
        }
        flushPendingLocalDraft()
        EasyTierPerformanceSignposts.workspaceTransition()
        workspaceTransitionEdge = networkTransitionEdge(from: previousValue, to: newValue)
        workspaceTransitionDistance = Self.networkTransitionDistance
        Task {
            await store.selectConfig(id: newValue)
            selectedConfigIDLocal = store.selectedConfigID
            loadDraft(for: store.selectedConfigID)
        }
    }

    func selectWorkspaceTab(_ tab: WorkspaceTab) {
        guard allowedWorkspaceTabs.contains(tab) else {
            selectedTabLocal = store.selectedTab == .services ? .status : store.selectedTab
            if store.selectedTab == .services { store.selectedTab = .status }
            return
        }
        guard tab != store.selectedTab else { return }
        flushPendingLocalDraft()
        EasyTierPerformanceSignposts.workspaceTransition()
        workspaceTransitionEdge =
            tab.motionIndex > store.selectedTab.motionIndex ? .trailing : .leading
        workspaceTransitionDistance = Self.tabTransitionDistance
        store.selectedTab = tab
    }

    func handlePendingPeerCardMerge(_ card: PeerCard?) {
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

    func requestDeleteSelectedConfig() {
        guard !store.selectedConfigIsRuntimeManaged else { return }
        if selectedConfigCanStop {
            showingDeleteRunningNetworkConfirmation = true
        } else {
            deleteSelectedConfig()
        }
    }

    func deleteSelectedConfig() {
        configApplyCoordinator.cancelPending()
        draftIsDirty = false
        Task { await store.deleteSelectedConfig() }
    }

    func configureRemoteMember(_ member: NetworkMemberStatus) {
        store.clearRemoteConfigSession()
        selectWorkspaceTab(.config)
        Task {
            await store.startRemoteConfigSession(member: member)
        }
    }

    func remoteConfigBinding() -> Binding<NetworkConfig>? {
        guard store.remoteConfigSession != nil else { return nil }
        return Binding(
            get: { store.remoteConfigSession?.config ?? NetworkConfig() },
            set: { newValue in
                store.remoteConfigSession?.config = newValue
            }
        )
    }

    @ViewBuilder
    func remoteConfigContent(session: RemoteConfigSession) -> some View {
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
            ConfigEditorView(
                config: config,
                members: store.selectedLiveMemberStatuses,
                remoteSession: session,
                onScrolledPastTopChange: { configEditorTitlebarScrollEdgeVisible = $0 }
            )
                .disabled(session.applyState.isApplying)
        }
    }

    func renameSelectedHostname(_ hostname: String) {
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

    func renameRemoteHostname(_ member: NetworkMemberStatus, hostname: String) async -> Bool {
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
        let intent: RuntimeIntent
        do {
            intent = try await store.upsertRemoteHostnameRuntimeIntent(
                networkName: networkName,
                member: member,
                desiredHostname: trimmed
            )
        } catch {
            store.lastError = error.localizedDescription
            return false
        }

        do {
            try await EasyTierRemoteRPCClient(rpcURL: rpcURL).patchHostname(instanceID: instanceID, hostname: trimmed)
        } catch {
            await store.markRuntimeIntent(intent.id, status: .unreachable)
            store.lastError = error.localizedDescription
            return false
        }

        if await waitForRemoteInstance(instanceID: instanceID, matches: { $0.hostname == trimmed }) {
            await store.markRuntimeIntent(intent.id, status: .applied)
            return true
        }

        let message = "Remote hostname change was sent but not confirmed yet. Runtime status may not have refreshed."
        store.recordNotice(message)
        store.lastError = message
        return true
    }

    func waitForRemoteInstance(instanceID: String, matches: (NetworkMemberStatus) -> Bool) async -> Bool {
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

    func networkTransitionEdge(from oldID: String?, to newID: String?) -> Edge {
        guard
            let oldIndex = configIndex(for: oldID),
            let newIndex = configIndex(for: newID),
            oldIndex != newIndex
        else {
            return .bottom
        }

        return newIndex > oldIndex ? .bottom : .top
    }

    func configIndex(for id: String?) -> Int? {
        guard let id else { return nil }
        return store.presentedConfigs.firstIndex { $0.id == id }
    }

    func draftConfigBinding() -> Binding<NetworkConfig>? {
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
                if !configTextFieldIsEditing {
                    scheduleLocalConfigApply()
                }
            }
        )
    }

    func scheduleLocalConfigApply() {
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

    func applyLocalConfigRequest(_ request: LocalConfigApplyRequest) async -> ConfigApplyResult {
        let result = await store.applyConfigDraft(
            configID: request.configID,
            draft: request.config,
            replacing: request.replacing
        )
        if result.succeeded,
           draftConfigID == request.configID,
           currentLocalDraft() == request.config {
            draftIsDirty = false
        }
        return result
    }

    func flushPendingLocalDraft() {
        guard draftIsDirty else { return }
        scheduleLocalConfigApply()
        Task { await configApplyCoordinator.flush() }
    }

    func performSelectedConnectionAction() {
        guard !store.selectedConfigIsRuntimeManaged else { return }
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
                           currentLocalDraft() == pendingDraft.config {
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

    func restartSelectedNetworkManually() {
        guard !store.selectedConfigIsRuntimeManaged else { return }
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
                       currentLocalDraft() == pendingDraft.config {
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

    func loadDraft(for selectedID: String?) {
        configTextFieldIsEditing = false
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

    func currentLocalDraft() -> NetworkConfig {
        var config = draftConfig
        config.network_secret = nil
        return config
    }

    func markNetworkSecretPersisted(
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

    func openImportTOML() {
        tomlPresentation = TOMLPresentation(mode: .import, text: "")
    }

    func openExportTOML() async {
        guard !store.selectedConfigIsRuntimeManaged else { return }
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
