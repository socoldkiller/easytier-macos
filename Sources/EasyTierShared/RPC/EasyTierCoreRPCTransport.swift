import Foundation

struct EasyTierCoreRPCTransport: EasyTierRPCTransport {
    var client: any EasyTierCoreClient
    var rpcURL: URL?
    var clientID: String

    init(client: any EasyTierCoreClient, rpcURL: URL?) {
        self.client = client
        self.rpcURL = rpcURL
        self.clientID = Self.clientID(for: rpcURL)
    }

    func call(_ request: EasyTierRPCRequest) async throws -> String {
        if let rpcURL {
            try await client.connectRPCClient(clientID: clientID, url: rpcURL)
        }
        return try await client.callJSONRPC(
            service: request.service,
            method: request.method,
            domain: request.domain,
            payload: request.payload
        )
    }

    private static func clientID(for rpcURL: URL?) -> String {
        guard let rpcURL else { return "default" }
        let hex = rpcURL.absoluteString.utf8.map { String(format: "%02x", Int($0)) }.joined()
        return "intent-rpc-\(hex)"
    }
}
