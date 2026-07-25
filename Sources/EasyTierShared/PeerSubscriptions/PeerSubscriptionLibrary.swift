import Foundation

enum PeerSubscriptionLibrary {
    struct RefreshResult {
        var subscriptions: [PeerSubscription]
        var failures: [(url: URL, message: String)]
        var issues: [(url: URL, issue: PeerSubscriptionImportIssue)]
    }

    static func fetch(
        from url: URL,
        using dataLoader: any PeerSubscriptionDataLoading,
        now: Date = Date()
    ) async throws -> PeerSubscriptionImportResult {
        let data = try await dataLoader.data(from: url)
        return try decodedSubscriptions(from: data, sourceURL: url, fetchedAt: now)
    }

    static func decode(_ json: String) throws -> PeerSubscriptionImportResult {
        try PeerSubscriptionImporter.decode(json)
    }

    static func refresh(
        _ subscriptions: [PeerSubscription],
        using dataLoader: any PeerSubscriptionDataLoading
    ) async -> RefreshResult {
        var refreshed = subscriptions
        var failures: [(url: URL, message: String)] = []
        var issues: [(url: URL, issue: PeerSubscriptionImportIssue)] = []
        var seenURLs: Set<URL> = []
        let urls = subscriptions.compactMap(\.subscriptionURL).filter { seenURLs.insert($0).inserted }

        for url in urls {
            do {
                let fetched = try await fetch(from: url, using: dataLoader)
                merge(fetched.subscriptions, from: url, into: &refreshed)
                issues.append(contentsOf: fetched.issues.map { (url, $0) })
            } catch {
                failures.append((url, error.localizedDescription))
            }
        }
        return RefreshResult(subscriptions: refreshed, failures: failures, issues: issues)
    }

    static func latency(for card: PeerCard, runtimeDetails: [String: NetworkInstanceRunningInfo]) -> Int? {
        guard !card.urls.isEmpty else { return nil }
        for detail in runtimeDetails.values {
            for pair in detail.peer_route_pairs ?? [] {
                for connection in pair.peer?.conns ?? [] {
                    let endpoints = [connection.tunnel?.local_addr?.url, connection.tunnel?.remote_addr?.url]
                    guard endpoints.compactMap({ $0 }).contains(where: card.matchesRuntimePeerURL),
                          let latency = connection.stats?.latency_us
                    else { continue }
                    return max(1, Int((Double(latency) / 1_000).rounded()))
                }
            }
        }
        return nil
    }

    static func additionalURLCount(for card: PeerCard, in config: NetworkConfig) -> Int {
        let existing = Set(config.peer_urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        return card.urls.count { !existing.contains($0) }
    }

    static func decodedSubscriptions(
        from data: Data,
        sourceURL: URL,
        fetchedAt: Date
    ) throws -> PeerSubscriptionImportResult {
        let result = try PeerSubscriptionImporter.decode(data)
        return PeerSubscriptionImportResult(subscriptions: result.subscriptions.map { subscription in
            var subscription = subscription
            subscription.subscriptionURL = sourceURL
            subscription.lastFetchedAt = fetchedAt
            return subscription
        }, issues: result.issues)
    }

    static func merge(
        _ fetched: [PeerSubscription],
        from sourceURL: URL,
        into subscriptions: inout [PeerSubscription]
    ) {
        for subscription in fetched {
            if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
                subscriptions[index] = subscription
            } else if let index = subscriptions.firstIndex(where: { $0.subscriptionURL == sourceURL }) {
                subscriptions[index].cards = subscription.cards
                subscriptions[index].lastFetchedAt = subscription.lastFetchedAt
                if !subscription.name.isEmpty {
                    subscriptions[index].name = subscription.name
                }
            }
        }
    }
}
