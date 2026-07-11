import Foundation

public extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var trimmedNilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

public extension Array {
    var nilIfEmpty: [Element]? {
        isEmpty ? nil : self
    }
}
