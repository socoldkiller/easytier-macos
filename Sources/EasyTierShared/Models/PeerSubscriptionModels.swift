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
        decoder.dateDecodingStrategy = .iso8601

        if let single = try? decoder.decode(PeerSubscription.self, from: data) {
            return [single]
        }
        if let array = try? decoder.decode([PeerSubscription].self, from: data) {
            return array
        }
        if let cards = try? decoder.decode([PeerCard].self, from: data), !cards.isEmpty {
            return [PeerSubscription(name: "Subscription", cards: cards)]
        }
        throw PeerSubscriptionDecodeError.invalidFormat
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

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Subscription JSON must be a single subscription object, an array of subscriptions, or an array of peer cards."
        }
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
