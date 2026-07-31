@preconcurrency import AppKit
import EasyTierShared
import SwiftUI

extension MainWindowView {
    @ViewBuilder
    var localConfigApplyStatus: some View {
        if store.selectedTab == .config,
           configApplyCoordinator.targetConfigID == draftConfigID {
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

    var selectedConfigCanStop: Bool {
        store.selectedConfigCanStop
    }

    var gatewayActionTitle: String {
        if isChangingGateway || gateway.isBusy { return "Working" }
        return gateway.desiredEnabled ? "Pause Services" : "Run Services"
    }

    var gatewayActionSystemImage: String {
        if isChangingGateway || gateway.isBusy { return "hourglass" }
        return gateway.desiredEnabled ? "pause.fill" : "play.fill"
    }

    var gatewayActionColor: Color {
        if isChangingGateway || gateway.isBusy {
            return Color(nsColor: .secondaryLabelColor)
        }
        return gateway.desiredEnabled ? EasyTierColors.statusError : .accentColor
    }

    var gatewayActionHelp: String {
        if isChangingGateway || gateway.isBusy { return "Updating published services" }
        return gateway.desiredEnabled
            ? "Pause all published services"
            : "Run published services"
    }

    func toggleGateway() {
        let enabled = !gateway.desiredEnabled
        Task {
            isChangingGateway = true
            gatewayControlError = nil
            defer { isChangingGateway = false }
            do {
                try await gateway.setGatewayEnabled(enabled)
            } catch {
                gatewayControlError = error.localizedDescription
            }
        }
    }

    var serviceCreationTargets: [PublishedServiceTargetOption] {
        PublishedServiceTargetOption.creationOptions(members: gateway.topologyMembers)
    }

    var serviceCreationAvailability: PublishedServiceCreationAvailability {
        PublishedServiceCreationAvailability(
            magicDNSState: gateway.magicDNSState,
            targets: serviceCreationTargets
        )
    }

    var canBeginPublishingService: Bool {
        store.persistenceIsReady && serviceCreationAvailability.isAvailable
    }

    var publishServiceHelp: String {
        serviceCreationAvailability.helpText
    }

    func beginPublishingService(preferredTargetPeerID: String? = nil) {
        guard canBeginPublishingService else { return }
        publishServiceRequest = PublishServiceRequest(
            preferredTargetPeerID: preferredTargetPeerID
        )
    }

    var selectedConfigIsReady: Bool {
        selectedConfigCanStop && store.selectedRuntimeReadinessPhase == .ready
    }

    var deleteConfirmationNetworkName: String {
        store.selectedConfig?.network_name.nilIfEmpty ?? "The selected network"
    }

    var selectedConfigHasRuntimeError: Bool {
        guard var instance = store.selectedRunningInstance else { return false }
        instance.detail = store.selectedRuntimeDetail
        return instance.runtimeErrorMessage != nil || instance.listenerErrorFromEvents != nil
    }

    var workspaceMotionID: String {
        if let session = store.remoteConfigSession {
            return "\(store.selectedTab.id)-remote-\(session.member.id)"
        }
        if store.selectedTab == .services {
            return store.selectedTab.id
        }
        return "\(store.selectedTab.id)-\(store.selectedConfigID ?? "none")"
    }

    var connectionActionTitle: String {
        if store.isBusy { return "Working" }
        if selectedConfigHasRuntimeError { return "Stop" }
        if selectedConfigCanStop { return selectedConfigIsReady ? "Pause" : "Stop" }
        return "Run"
    }

    var connectionActionSystemImage: String {
        if store.isBusy { return "hourglass" }
        if selectedConfigHasRuntimeError || selectedConfigCanStop { return "cable.connector.slash" }
        return "cable.connector"
    }

    var connectionActionColor: Color {
        if store.isBusy { return Color(nsColor: .secondaryLabelColor) }
        if selectedConfigHasRuntimeError || selectedConfigCanStop { return EasyTierColors.statusError }
        return .accentColor
    }

    var connectionActionHelp: String {
        if store.isBusy { return "Working" }
        if selectedConfigHasRuntimeError { return "Stop selected network" }
        if selectedConfigIsReady { return "Pause selected network" }
        if selectedConfigCanStop { return "Stop selected network while it is starting" }
        return "Run selected network"
    }

    func applyRemoteToolbarChanges() async {
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
    func remoteApplyButtonLabel(for session: RemoteConfigSession) -> some View {
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

    func remoteApplyButtonIsDisabled(for session: RemoteConfigSession) -> Bool {
        if session.isLoading || session.loadError != nil || session.applyState.isApplying || store.isBusy {
            return true
        }
        if case .failed = session.applyState {
            return false
        }
        return !session.hasUnsavedChanges
    }

    func remoteApplyButtonHelp(for session: RemoteConfigSession) -> String {
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

    func connectionState(for config: NetworkConfig) -> ConnectionGlyphState {
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
}
