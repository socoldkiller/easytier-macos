@preconcurrency import AppKit
import EasyTierShared
import SwiftUI

extension MainWindowView {
    var sidebar: some View {

        return Group {
            if networkSearchQuery.isEmpty {
                List(selection: $selectedConfigIDLocal) {
                    Section {
                        ForEach(store.presentedConfigs) { stored in
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
        .onChange(of: networkSearchQuery.isEmpty ? [] : networkSearchResultIDs) { _, ids in
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
        .scrollIndicators(.hidden, axes: [.vertical, .horizontal])
        .hideScrollViewScrollers()
        .easyTierSafeAreaBar(edge: .bottom) {
            HStack {
                Button {
                    flushPendingLocalDraft()
                    Task { await store.addConfig() }
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add network")
                .accessibilityLabel(Text("Add network"))
                .disabled(
                    !store.persistenceIsReady
                        || !store.allowsLocalConfigurationMutation
                        || store.isBusy
                        || store.isQuitting
                )
                Button(role: .destructive) {
                    requestDeleteSelectedConfig()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete selected network")
                .accessibilityLabel(Text("Delete selected network"))
                .disabled(
                    !store.persistenceIsReady
                        || !store.allowsLocalConfigurationMutation
                        || store.selectedConfigID == nil
                        || store.selectedConfigIsRuntimeManaged
                        || store.isBusy
                        || store.isQuitting
                )
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
    var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            WorkspaceTabPicker(selection: $selectedTabLocal, tabs: allowedWorkspaceTabs)
                .toolbarAutoHidden(toolbarControlsHidden, reduceMotion: reduceMotion)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if store.selectedTab == .services {
                Button("Publish Service", systemImage: "plus") {
                    beginPublishingService()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!canBeginPublishingService)
                .help(publishServiceHelp)
            }

            if store.selectedTab == .services {
                Button {
                    toggleGateway()
                } label: {
                    Label(
                        gatewayActionTitle,
                        systemImage: gatewayActionSystemImage
                    )
                    .foregroundStyle(gatewayActionColor)
                }
                .disabled(!store.persistenceIsReady || isChangingGateway || gateway.isBusy)
                .help(gatewayActionHelp)
            } else if let remoteSession = remoteToolbarSession {
                Button {
                    Task { await applyRemoteToolbarChanges() }
                } label: {
                    remoteApplyButtonLabel(for: remoteSession)
                }
                .disabled(!store.persistenceIsReady || remoteApplyButtonIsDisabled(for: remoteSession))
                .help(remoteApplyButtonHelp(for: remoteSession))
                .toolbarAutoHidden(toolbarControlsHidden, reduceMotion: reduceMotion)
            } else {
                localConfigApplyStatus

                Button {
                    performSelectedConnectionAction()
                } label: {
                    Label(
                        connectionActionTitle,
                        systemImage: connectionActionSystemImage
                    )
                    .foregroundStyle(connectionActionColor)
                }
                .disabled(
                    !store.persistenceIsReady
                        || store.selectedConfig == nil
                        || store.selectedConfigIsRuntimeManaged
                        || store.isBusy
                )
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
                    .disabled(
                        !store.persistenceIsReady
                            || !selectedConfigCanStop
                            || store.selectedConfigIsRuntimeManaged
                            || store.isBusy
                    )

                    Divider()

                    Button("Import TOML") {
                        flushPendingLocalDraft()
                        openImportTOML()
                    }
                    .disabled(!store.persistenceIsReady || !store.allowsLocalConfigurationMutation)
                    Button("Export TOML") {
                        Task {
                            await configApplyCoordinator.flush()
                            await openExportTOML()
                        }
                    }
                    .disabled(
                        !store.persistenceIsReady
                            || store.selectedConfig == nil
                            || store.selectedConfigIsRuntimeManaged
                    )
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .toolbarAutoHidden(toolbarControlsHidden, reduceMotion: reduceMotion)
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                openSettings(tab: .general)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("EasyTier Settings")
            .toolbarAutoHidden(toolbarControlsHidden, reduceMotion: reduceMotion)
        }
    }
}
