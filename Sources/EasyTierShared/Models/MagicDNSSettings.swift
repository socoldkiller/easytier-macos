import Foundation

public struct MagicDNSSettings: Codable, Equatable, Sendable {
    public var dnsSuffix: String

    public init(dnsSuffix: String = Self.defaultDNSSuffix) throws {
        self.dnsSuffix = try Self.normalizedDNSSuffix(dnsSuffix)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let dnsSuffix = try container.decodeIfPresent(String.self, forKey: .dnsSuffix) ?? Self.defaultDNSSuffix
        self.dnsSuffix = try Self.normalizedDNSSuffix(dnsSuffix)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dnsSuffix, forKey: .dnsSuffix)
    }

    public static let `default` = try! MagicDNSSettings()
    public static let defaultDNSSuffix = "et.net."

    public static func normalizedDNSSuffix(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimmed.isEmpty ? defaultDNSSuffix : trimmed

        guard !suffix.contains("://") else {
            throw MagicDNSSettingsValidationError.invalidDNSSuffix("DNS suffix must not include a protocol.")
        }

        let dotted = suffix.hasSuffix(".") ? suffix : suffix + "."
        let labels = dotted.dropLast().split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else {
            throw MagicDNSSettingsValidationError.invalidDNSSuffix("DNS suffix cannot be empty.")
        }

        for label in labels {
            guard (1...63).contains(label.count) else {
                throw MagicDNSSettingsValidationError.invalidDNSSuffix("DNS suffix labels must be 1 to 63 characters.")
            }
            guard label.first.map(Self.isDNSAlphanumeric) == true,
                  label.last.map(Self.isDNSAlphanumeric) == true
            else {
                throw MagicDNSSettingsValidationError.invalidDNSSuffix("DNS suffix labels must start and end with a letter or number.")
            }
            guard label.allSatisfy({ Self.isDNSAlphanumeric($0) || $0 == "-" }) else {
                throw MagicDNSSettingsValidationError.invalidDNSSuffix("DNS suffix may contain only letters, numbers, hyphens, and dots.")
            }
        }

        return dotted.lowercased()
    }

    private static func isDNSAlphanumeric(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        return (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
            || (48...57).contains(scalar.value)
    }

    private enum CodingKeys: String, CodingKey {
        case dnsSuffix
    }
}

public enum MagicDNSSettingsValidationError: LocalizedError, Equatable {
    case invalidDNSSuffix(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidDNSSuffix(message):
            message
        }
    }
}
