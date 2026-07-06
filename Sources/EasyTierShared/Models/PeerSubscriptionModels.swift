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

    enum CodingKeys: String, CodingKey {
        case id, name, subscriptionURL, cards, lastFetchedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        id = try container.decodeStringIfPresent("id", "subscriptionURL", "url", "name") ?? UUID().uuidString.lowercased()
        name = try container.decodeStringIfPresent("name", "title", "subscription") ?? "Untitled Subscription"
        if let urlString = try container.decodeStringIfPresent("subscriptionURL", "subscription_url", "url", "source") {
            subscriptionURL = URL(string: urlString)
        } else if let url = try? container.decodeIfPresent(URL.self, forKeys: "subscriptionURL", "subscription_url", "url", "source") {
            subscriptionURL = url
        } else {
            subscriptionURL = nil
        }
        let cardKeyNames = ["cards", "peers", "nodes"]
        let cardKey = cardKeyNames.first { container.contains(AnyCodingKey(stringValue: $0)) }
        guard let cardKey else {
            throw DecodingError.keyNotFound(
                AnyCodingKey(stringValue: "cards"),
                .init(codingPath: decoder.codingPath, debugDescription: "PeerSubscription requires a `cards` field.")
            )
        }
        cards = try container.decodeLossyArray(PeerCard.self, forKeys: cardKey) ?? []
        lastFetchedAt = try container.decodeIfPresent(Date.self, forKeys: "lastFetchedAt", "last_fetched_at", "fetchedAt")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(subscriptionURL, forKey: .subscriptionURL)
        try container.encode(cards, forKey: .cards)
        try container.encodeIfPresent(lastFetchedAt, forKey: .lastFetchedAt)
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

    enum CodingKeys: String, CodingKey {
        case id, name, proto, urls, note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let decodedID = try container.decodeStringIfPresent("id", "cardId", "key") ?? UUID().uuidString.lowercased()
        let decodedName = try container.decodeStringIfPresent("name", "title", "label") ?? "Unnamed"
        var decodedProto = try container.decodeStringIfPresent("proto", "protocol", "tunnel", "scheme") ?? ""
        var decodedURLs = try container.decodeLossyArray(String.self, forKeys: "urls", "url", "peers", "peer_urls", "endpoints") ?? []

        decodedURLs = decodedURLs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if decodedProto.isEmpty {
            decodedProto = PeerCard.inferProto(from: decodedURLs)
        }

        let decodedNote = try container.decodeStringIfPresent("note", "description", "comment")

        self.id = decodedID
        self.name = decodedName
        self.proto = decodedProto
        self.urls = decodedURLs
        self.note = decodedNote
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(proto, forKey: .proto)
        try container.encode(urls, forKey: .urls)
        try container.encodeIfPresent(note, forKey: .note)
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

public enum PeerSubscriptionCodec {
    public static func decode(_ data: Data) throws -> [PeerSubscription] {
        let decoder = JSONDecoder()
        guard let config = try? decoder.decode(OutboundSubscriptionConfig.self, from: data) else {
            throw PeerSubscriptionDecodeError.invalidFormat
        }

        let cards = config.importablePeerCards()
        guard !cards.isEmpty else {
            throw PeerSubscriptionDecodeError.noImportableOutbounds
        }

        return [PeerSubscription(name: "Node Subscription", cards: cards)]
    }

    public static func decode(_ string: String) throws -> [PeerSubscription] {
        guard let data = string.data(using: .utf8) else {
            throw PeerSubscriptionDecodeError.invalidFormat
        }
        return try decode(data)
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
    var outbounds: [SubscriptionOutbound]

    func importablePeerCards() -> [PeerCard] {
        var usedIDs: Set<String> = []
        return outbounds.enumerated().compactMap { index, outbound in
            guard outbound.isImportable,
                  let server = outbound.normalizedServer,
                  let port = outbound.serverPort?.value
            else {
                return nil
            }

            let scheme = outbound.normalizedType
            let name = outbound.normalizedTag ?? "\(server):\(port)"
            let baseID = outbound.normalizedTag ?? "\(scheme)-\(server)-\(port)"
            let id = uniqueID(from: baseID, fallbackIndex: index, usedIDs: &usedIDs)
            return PeerCard(
                id: id,
                name: name,
                proto: scheme,
                urls: ["\(scheme)://\(server):\(port)"],
                note: "Imported \(scheme) peer from subscription."
            )
        }
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
        tag?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var normalizedType: String {
        type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedServer: String? {
        server?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
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

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer where Key == AnyCodingKey {
    func key(_ name: String) -> AnyCodingKey { AnyCodingKey(stringValue: name) }

    func decodeStringIfPresent(_ keys: String...) throws -> String? {
        for keyName in keys {
            if let value = try decodeIfPresent(String.self, forKey: key(keyName)) { return value }
        }
        return nil
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKeys keys: String...) throws -> T? {
        for keyName in keys {
            if let value = try decodeIfPresent(type, forKey: key(keyName)) { return value }
        }
        return nil
    }

    func decodeLossyArray<T: Decodable>(_ type: T.Type, forKeys keys: String...) throws -> [T]? {
        for keyName in keys {
            let k = key(keyName)
            guard contains(k) else { continue }
            var container = try nestedUnkeyedContainer(forKey: k)
            var output: [T] = []
            while !container.isAtEnd {
                if let value = try? container.decode(T.self) {
                    output.append(value)
                } else {
                    _ = try? container.decode(DiscardedDecodable.self)
                }
            }
            return output
        }
        return nil
    }
}

private struct DiscardedDecodable: Decodable {}
