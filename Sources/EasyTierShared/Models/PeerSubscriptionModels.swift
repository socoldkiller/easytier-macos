import Foundation

public struct PeerSubscription: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var subscriptionURL: URL?
    public var cards: [PeerCard]
    public var lastFetchedAt: Date?

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        subscriptionURL: URL? = nil,
        cards: [PeerCard] = [],
        lastFetchedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.subscriptionURL = subscriptionURL
        self.cards = cards
        self.lastFetchedAt = lastFetchedAt
    }

}

public struct PeerCard: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var proto: String
    public var urls: [String]
    public var note: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        proto: String = "",
        urls: [String] = [],
        note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.proto = proto
        self.urls = urls
        self.note = note
    }

    public static func inferProto(from urls: [String]) -> String {
        let schemes = urls.compactMap { URL(string: $0)?.scheme?.lowercased() }
        guard !schemes.isEmpty else { return "" }
        let unique = Array(Set(schemes)).sorted()
        return unique.joined(separator: ", ")
    }

    public func matchesRuntimePeerURL(_ runtimeURL: String) -> Bool {
        guard !runtimeURL.isEmpty else { return false }
        let normalizedRuntime = PeerCard.normalize(runtimeURL)
        return urls.contains { PeerCard.normalize($0) == normalizedRuntime }
    }

    public static func normalize(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        if let parsed = URL(string: trimmed) {
            let scheme = parsed.scheme?.lowercased() ?? ""
            let host = parsed.host?.lowercased() ?? ""
            let port = parsed.port.map { ":\($0)" } ?? ""
            if !host.isEmpty {
                return "\(scheme)://\(host)\(port)"
            }
        }
        return trimmed
    }
}

public struct PeerSubscriptionImportResult: Equatable, Sendable {
    public var subscriptions: [PeerSubscription]
    public var issues: [PeerSubscriptionImportIssue]
}

public struct PeerSubscriptionImportIssue: Equatable, Sendable {
    public var outboundIndex: Int
    public var message: String
}

public enum PeerSubscriptionImporter {
    public static func decode(_ data: Data) throws -> PeerSubscriptionImportResult {
        let decoder = JSONDecoder()
        let config: OutboundSubscriptionConfig
        do {
            config = try decoder.decode(OutboundSubscriptionConfig.self, from: data)
        } catch {
            throw PeerSubscriptionDecodeError.invalidFormat
        }

        let imported = config.importablePeerCards()
        let cards = imported.cards
        guard !cards.isEmpty else {
            throw PeerSubscriptionDecodeError.noImportableOutbounds
        }

        return PeerSubscriptionImportResult(
            subscriptions: [PeerSubscription(name: "Node Subscription", cards: cards)],
            issues: imported.issues
        )
    }

    public static func decode(_ string: String) throws -> PeerSubscriptionImportResult {
        try decode(Data(string.utf8))
    }
}

public enum PeerSubscriptionDecodeError: Error, LocalizedError {
    case invalidFormat
    case noImportableOutbounds

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Expected subscription JSON with top-level outbounds."
        case .noImportableOutbounds:
            return "Expected subscription JSON with EasyTier protocol outbounds."
        }
    }
}

private struct OutboundSubscriptionConfig: Decodable {
    var outbounds: [ImportedOutbound]

    func importablePeerCards() -> (cards: [PeerCard], issues: [PeerSubscriptionImportIssue]) {
        var usedIDs: Set<String> = []
        var cards: [PeerCard] = []
        var issues: [PeerSubscriptionImportIssue] = []
        for (index, importedOutbound) in outbounds.enumerated() {
            guard let outbound = importedOutbound.value else {
                issues.append(.init(outboundIndex: index, message: "Outbound has an invalid structure or value type."))
                continue
            }
            guard outbound.isImportable else {
                issues.append(.init(outboundIndex: index, message: "Unsupported outbound type `\(outbound.normalizedType)`."))
                continue
            }
            guard let server = outbound.normalizedServer, let port = outbound.serverPort?.value else {
                issues.append(.init(outboundIndex: index, message: "EasyTier outbound is missing server or server_port."))
                continue
            }

            let scheme = outbound.normalizedType
            let name = outbound.normalizedTag ?? "\(server):\(port)"
            let baseID = outbound.normalizedTag ?? "\(scheme)-\(server)-\(port)"
            let id = uniqueID(from: baseID, fallbackIndex: index, usedIDs: &usedIDs)
            cards.append(PeerCard(
                id: id,
                name: name,
                proto: scheme,
                urls: ["\(scheme)://\(server):\(port)"],
                note: "Imported \(scheme) peer from subscription."
            ))
        }
        return (cards, issues)
    }

    private func uniqueID(from rawValue: String, fallbackIndex: Int, usedIDs: inout Set<String>) -> String {
        let normalized = rawValue
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber ? character : "-"
            }
            .reduce(into: "") { output, character in
                if character == "-", output.last == "-" { return }
                output.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        let base = normalized.isEmpty ? "subscription-\(fallbackIndex + 1)" : normalized
        var candidate = base
        var suffix = 2
        while usedIDs.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        usedIDs.insert(candidate)
        return candidate
    }
}

private struct ImportedOutbound: Decodable {
    var value: SubscriptionOutbound?

    init(from decoder: Decoder) throws {
        value = try? SubscriptionOutbound(from: decoder)
    }
}

private struct SubscriptionOutbound: Decodable {
    var type: String
    var tag: String?
    var server: String?
    var serverPort: IntOrString?

    private enum CodingKeys: String, CodingKey {
        case type, tag, server
        case serverPort = "server_port"
    }

    var normalizedTag: String? {
        tag?.trimmedNilIfEmpty
    }

    var normalizedType: String {
        type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedServer: String? {
        server?.trimmedNilIfEmpty
    }

    var isImportable: Bool {
        Self.easyTierProtocols.contains(normalizedType)
    }

    private static let easyTierProtocols: Set<String> = ["tcp", "udp", "wg", "ws", "wss", "quic", "faketcp"]
}

private struct IntOrString: Decodable {
    var value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            value = intValue
            return
        }
        if let stringValue = try? container.decode(String.self),
           let intValue = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            value = intValue
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "server_port must be an integer.")
    }
}
