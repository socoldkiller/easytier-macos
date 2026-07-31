import Foundation
import Network

final class LoopbackSSOCallbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.kkrainbow.easytier.native-sso-callback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var callbackContinuation: CheckedContinuation<String, Error>?
    private var bufferedResult: Result<String, Error>?

    func start(expectedState: String) async throws -> UInt16 {
        let expectedState = expectedState
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, expectedState: expectedState)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port else {
                        continuation.resume(throwing: BrowserSSOError.callbackUnavailable)
                        return
                    }
                    continuation.resume(returning: port.rawValue)
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    self?.finish(.failure(error))
                    continuation.resume(throwing: BrowserSSOError.callbackUnavailable)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForTicket() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if let bufferedResult {
                        self.bufferedResult = nil
                        continuation.resume(with: bufferedResult)
                    } else {
                        callbackContinuation = continuation
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        listener?.cancel()
        finish(.failure(CancellationError()))
    }

    private func accept(_ connection: NWConnection, expectedState: String) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let result = data.flatMap { Self.ticket(from: $0, expectedState: expectedState) }
            let accepted = result != nil
            sendResponse(accepted: accepted, over: connection)
            finish(result.map(Result.success) ?? .failure(BrowserSSOError.callbackRejected))
        }
    }

    private func sendResponse(accepted: Bool, over connection: NWConnection) {
        let status = accepted ? "200 OK" : "400 Bad Request"
        let message = accepted
            ? "Sign-in complete. You can return to EasyTier."
            : "EasyTier could not accept this sign-in response."
        let body = "<!doctype html><meta charset=\"utf-8\"><title>EasyTier</title><p>\(message)</p>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<String, Error>) {
        listener?.cancel()
        lock.withLock {
            if let callbackContinuation {
                self.callbackContinuation = nil
                callbackContinuation.resume(with: result)
            } else if bufferedResult == nil {
                bufferedResult = result
            }
        }
    }

    static func ticket(from request: Data, expectedState: String) -> String? {
        guard request.count <= 16_384,
              let text = String(data: request, encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first,
              requestLine.hasPrefix("GET "),
              requestLine.hasSuffix(" HTTP/1.1"),
              let target = requestLine.split(separator: " ", maxSplits: 2).dropFirst().first,
              let components = URLComponents(string: String(target)),
              components.path == "/easytier/callback",
              let items = components.queryItems
        else {
            return nil
        }

        let states = items.filter { $0.name == "state" }.compactMap(\.value)
        let tickets = items.filter { $0.name == "ticket" }.compactMap(\.value)
        guard states.count == 1,
              tickets.count == 1,
              tickets[0].count <= 4096,
              constantTimeEqual(states[0], expectedState)
        else {
            return nil
        }
        return tickets[0]
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}
