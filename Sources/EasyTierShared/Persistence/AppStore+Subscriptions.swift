import Foundation
import Observation
import TOML

extension EasyTierAppStore {
    public func addPeerSubscription(url: URL) async {
        do {
            let fetched = try await PeerSubscriptionLibrary.fetch(
                from: url,
                using: peerSubscriptionDataLoader
            )
            var state = try stateForStorage()
            state.peerSubscriptions.append(contentsOf: fetched.subscriptions)
            try await commitPersistenceState(state)
            log("Added \(fetched.subscriptions.count) subscription(s) from \(url.absoluteString).")
            logPeerSubscriptionIssues(fetched.issues, source: url.absoluteString)
        } catch {
            setLastError(error)
            log("Failed to fetch subscription from \(url.absoluteString): \(error.localizedDescription)")
        }
    }

    public func addPeerSubscription(json: String) async throws {
        let decoded = try PeerSubscriptionLibrary.decode(json)
        var state = try stateForStorage()
        state.peerSubscriptions.append(contentsOf: decoded.subscriptions)
        try await commitPersistenceState(state)
        log("Added \(decoded.subscriptions.count) subscription(s) from pasted JSON.")
        logPeerSubscriptionIssues(decoded.issues, source: "pasted JSON")
    }

    public func refreshPeerSubscriptions() async {
        guard peerSubscriptions.contains(where: { $0.subscriptionURL != nil }) else { return }
        isRefreshingPeerSubscriptions = true
        defer { isRefreshingPeerSubscriptions = false }

        let result = await PeerSubscriptionLibrary.refresh(
            peerSubscriptions,
            using: peerSubscriptionDataLoader
        )
        do {
            var state = try stateForStorage()
            state.peerSubscriptions = result.subscriptions
            try await commitPersistenceState(state)
        } catch {
            setLastError(error)
            log("Subscriptions refresh could not be saved: \(error.localizedDescription)")
            return
        }
        for failure in result.failures {
            log("Failed to refresh subscription from \(failure.url.absoluteString): \(failure.message)")
        }
        for issue in result.issues {
            log("Skipped subscription outbound \(issue.issue.outboundIndex + 1) from \(issue.url.absoluteString): \(issue.issue.message)")
        }
        log("Subscriptions refresh complete.")
    }

    func logPeerSubscriptionIssues(_ issues: [PeerSubscriptionImportIssue], source: String) {
        for issue in issues {
            log("Skipped subscription outbound \(issue.outboundIndex + 1) from \(source): \(issue.message)")
        }
    }

    public func peerCardLatency(for card: PeerCard) -> Int? {
        PeerSubscriptionLibrary.latency(for: card, runtimeDetails: runtimeDetails)
    }

    public enum PeerCardMergeResult: Equatable {
        case added(count: Int)
        case alreadyPresent
        case noSelectedConfig
    }

    /// Checks how a card would merge against the currently selected config's peer_urls.
    /// Does NOT mutate state — the actual merge is performed by the view layer against its draft.
    public func previewPeerCardMerge(_ card: PeerCard) -> PeerCardMergeResult {
        guard let selectedID = selectedConfigID,
              let config = configs.first(where: { $0.id == selectedID })
        else {
            return .noSelectedConfig
        }
        let count = PeerSubscriptionLibrary.additionalURLCount(for: card, in: config)
        guard count > 0 else {
            return .alreadyPresent
        }
        return .added(count: count)
    }

    func uniqueNetworkName() -> String {
        let base = "easytier"
        let existing = Set(configs.map(\.network_name))
        if !existing.contains(base) { return base }
        for index in 2...999 where !existing.contains("\(base)-\(index)") {
            return "\(base)-\(index)"
        }
        return "\(base)-\(UUID().uuidString.prefix(6))"
    }

    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    static let remoteConfigConfirmationAttempts = 12
}

public struct LogEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}
