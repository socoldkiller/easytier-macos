import EasyTierShared
import Foundation

enum NetworkManagementSource: Equatable, Sendable {
    case local
    case configServer
}

struct NetworkPresentationItem: Identifiable, Equatable, Sendable {
    let id: String
    let networkName: String
    let hostname: String?
    let source: NetworkManagementSource
    let readiness: RuntimeReadinessPhase
    let connectionState: ConnectionGlyphState
    let isSelected: Bool
    let canToggle: Bool

    var statusText: String {
        switch connectionState {
        case .idle: "Not Connected"
        case .connecting: readiness == .starting ? "Starting" : "Connecting"
        case .connected: "Connected"
        case .error: "Needs Attention"
        }
    }
}

struct NetworkCollectionSummary: Equatable, Sendable {
    let totalCount: Int
    let connectedCount: Int
    let connectingCount: Int
    let failedCount: Int
    let stoppedCount: Int
    let connectionState: ConnectionGlyphState
    let displayText: String

    init(items: [NetworkPresentationItem]) {
        totalCount = items.count
        connectedCount = items.count { $0.connectionState == .connected }
        connectingCount = items.count { $0.connectionState == .connecting }
        failedCount = items.count { $0.connectionState == .error }
        stoppedCount = items.count { $0.connectionState == .idle }

        if failedCount > 0 {
            connectionState = .error
        } else if connectingCount > 0 {
            connectionState = .connecting
        } else if connectedCount > 0 {
            connectionState = .connected
        } else {
            connectionState = .idle
        }

        if totalCount == 0 {
            displayText = "No Networks"
        } else if stoppedCount == totalCount {
            displayText = "All Networks Stopped"
        } else {
            var buckets: [String] = []
            if connectedCount > 0 { buckets.append("\(connectedCount) Connected") }
            if connectingCount > 0 { buckets.append("\(connectingCount) Connecting") }
            if failedCount > 0 { buckets.append("\(failedCount) Issue\(failedCount == 1 ? "" : "s")") }
            if stoppedCount > 0 { buckets.append("\(stoppedCount) Stopped") }
            displayText = buckets.joined(separator: " · ")
        }
    }
}

@MainActor
enum NetworkPresentationResolver {
    static func items(for store: EasyTierAppStore) -> [NetworkPresentationItem] {
        let source: NetworkManagementSource = store.configurationAuthority == .local
            ? .local
            : .configServer

        return store.presentedConfigs.map { config in
            let readiness = store.runtimeReadinessPhase(matching: config)
            let connectionState = connectionState(
                for: config,
                readiness: readiness,
                store: store
            )
            return NetworkPresentationItem(
                id: config.id,
                networkName: config.network_name.nilIfEmpty ?? "Unnamed Network",
                hostname: config.hostname?.nilIfEmpty,
                source: source,
                readiness: readiness,
                connectionState: connectionState,
                isSelected: config.id == store.selectedConfigID,
                canToggle: source == .local
            )
        }
    }

    static func summary(for store: EasyTierAppStore) -> NetworkCollectionSummary {
        NetworkCollectionSummary(items: items(for: store))
    }

    private static func connectionState(
        for config: NetworkConfig,
        readiness: RuntimeReadinessPhase,
        store: EasyTierAppStore
    ) -> ConnectionGlyphState {
        if store.lastError != nil, config.id == store.selectedConfigID { return .error }
        if store.runtimeTransitionsByConfigID[config.id] != nil { return .connecting }

        switch readiness {
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
