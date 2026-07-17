import Foundation

package protocol PeerSubscriptionDataLoading: Sendable {
    func data(from url: URL) async throws -> Data
}

package struct URLSessionPeerSubscriptionDataLoader: PeerSubscriptionDataLoading {
    private let session: URLSession

    package init(session: URLSession) {
        self.session = session
    }

    package func data(from url: URL) async throws -> Data {
        let (data, _) = try await session.data(from: url)
        return data
    }
}
