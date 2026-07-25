import Foundation

struct EasyTierProtobufUUID: Decodable, Sendable {
    let part1: UInt32
    let part2: UInt32
    let part3: UInt32
    let part4: UInt32

    var stringValue: String {
        let bytes = (
            UInt8(truncatingIfNeeded: part1 >> 24),
            UInt8(truncatingIfNeeded: part1 >> 16),
            UInt8(truncatingIfNeeded: part1 >> 8),
            UInt8(truncatingIfNeeded: part1),
            UInt8(truncatingIfNeeded: part2 >> 24),
            UInt8(truncatingIfNeeded: part2 >> 16),
            UInt8(truncatingIfNeeded: part2 >> 8),
            UInt8(truncatingIfNeeded: part2),
            UInt8(truncatingIfNeeded: part3 >> 24),
            UInt8(truncatingIfNeeded: part3 >> 16),
            UInt8(truncatingIfNeeded: part3 >> 8),
            UInt8(truncatingIfNeeded: part3),
            UInt8(truncatingIfNeeded: part4 >> 24),
            UInt8(truncatingIfNeeded: part4 >> 16),
            UInt8(truncatingIfNeeded: part4 >> 8),
            UInt8(truncatingIfNeeded: part4)
        )
        return UUID(uuid: bytes).uuidString.lowercased()
    }
}
