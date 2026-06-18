import Foundation

public struct SearchQuery: Equatable, Sendable {
    public var rawValue: String
    public var tokens: [String]

    public init(_ rawValue: String) {
        self.rawValue = rawValue
        tokens = Self.normalized(rawValue)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    public var isEmpty: Bool {
        tokens.isEmpty
    }

    public func matches(_ fields: [String]) -> Bool {
        guard !isEmpty else { return true }

        let normalizedFields = fields
            .map(Self.normalized)
            .joined(separator: "\n")
        let compactFields = Self.compacted(normalizedFields)

        return tokens.allSatisfy { token in
            if normalizedFields.contains(token) { return true }

            let compactToken = Self.compacted(token)
            guard !compactToken.isEmpty else { return false }
            return compactFields.contains(compactToken)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
    }

    private static func compacted(_ value: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return String(value.unicodeScalars.filter { !separators.contains($0) })
    }
}
