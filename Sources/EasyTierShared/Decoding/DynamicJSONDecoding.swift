import Foundation

struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct DiscardedDecodable: Decodable {}

extension KeyedDecodingContainer {
    func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return Int(clamping: value) }
        if let value = try? decodeIfPresent(UInt64.self, forKey: key) { return Int(clamping: value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int(value) }
        return nil
    }

    func decodeFlexibleInt64(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return Int64(value) }
        if let value = try? decodeIfPresent(UInt64.self, forKey: key) { return Int64(clamping: value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int64(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int64(value) }
        return nil
    }

    func decodeFlexibleDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return Double(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Double(value) }
        return nil
    }

    func decodeFlexibleString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(UInt64.self, forKey: key) { return String(value) }
        return nil
    }

    func decodeLossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T]? {
        guard contains(key) else { return nil }
        var container = try nestedUnkeyedContainer(forKey: key)
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
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    func key(_ name: String) -> AnyCodingKey {
        AnyCodingKey(stringValue: name)
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKeys keys: String...) throws -> T? {
        for keyName in keys {
            if let value = try decodeIfPresent(type, forKey: key(keyName)) { return value }
        }
        return nil
    }

    func decodeStringIfPresent(_ keys: String...) throws -> String? {
        for keyName in keys {
            if let value = try decodeIfPresent(String.self, forKey: key(keyName)) { return value }
        }
        return nil
    }

    func decodeBoolIfPresent(_ keys: String...) throws -> Bool? {
        for keyName in keys {
            if let value = try decodeIfPresent(Bool.self, forKey: key(keyName)) { return value }
        }
        return nil
    }

    func decodeFlexibleInt(forKeys keys: String...) -> Int? {
        keys.lazy.compactMap { decodeFlexibleInt(forKey: key($0)) }.first
    }

    func decodeFlexibleInt64(forKeys keys: String...) -> Int64? {
        keys.lazy.compactMap { decodeFlexibleInt64(forKey: key($0)) }.first
    }

    func decodeFlexibleDouble(forKeys keys: String...) -> Double? {
        keys.lazy.compactMap { decodeFlexibleDouble(forKey: key($0)) }.first
    }

    func decodeFlexibleString(forKeys keys: String...) -> String? {
        keys.lazy.compactMap { decodeFlexibleString(forKey: key($0)) }.first
    }

    func decodeLossyArray<T: Decodable>(_ type: T.Type, forKeys keys: String...) throws -> [T]? {
        for keyName in keys where contains(key(keyName)) {
            return try decodeLossyArray(type, forKey: key(keyName))
        }
        return nil
    }
}
