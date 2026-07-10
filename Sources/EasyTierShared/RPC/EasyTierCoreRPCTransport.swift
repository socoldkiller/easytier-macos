import Foundation

package struct EasyTierCoreRPCTransport: EasyTierRPCTransport {
    package let rpcURL: URL
    package let clientID: String

    private let client: any EasyTierCoreClient

    package init(
        client: any EasyTierCoreClient,
        rpcURL: URL,
        clientID: String? = nil
    ) {
        self.client = client
        self.rpcURL = rpcURL
        self.clientID = clientID ?? Self.clientID(for: rpcURL)
    }

    package func call(_ request: EasyTierRPCRequest) async throws -> String {
        try await client.callJSONRPC(
            clientID: clientID,
            url: rpcURL,
            service: request.service,
            method: request.method,
            domain: request.domain,
            payload: request.payload
        )
    }

    private static func clientID(for rpcURL: URL) -> String {
        let hex = rpcURL.absoluteString.utf8.map { String(format: "%02x", Int($0)) }.joined()
        return "rpc-\(hex)"
    }
}
