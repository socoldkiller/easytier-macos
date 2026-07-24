import Darwin
import EasyTierShared
import Foundation

protocol MagicDNSResolving: Sendable {
    func resolveIPv4(hostname: String) async -> Set<String>
}

struct EasyTierMagicDNSResolver: MagicDNSResolving {
    private let serverIPv4: String
    private let serverPort: UInt16
    private let timeoutMilliseconds: Int

    init(
        serverIPv4: String = MagicDNSSystemResolverConfigurator.resolverIP,
        serverPort: UInt16 = 53,
        timeoutMilliseconds: Int = 1_000
    ) {
        self.serverIPv4 = serverIPv4
        self.serverPort = serverPort
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    func resolveIPv4(hostname: String) async -> Set<String> {
        let serverIPv4 = serverIPv4
        let serverPort = serverPort
        let timeoutMilliseconds = timeoutMilliseconds
        return await Task.detached(priority: .utility) {
            let queryID = UInt16.random(in: .min ... .max)
            guard let query = MagicDNSMessage.makeAQuery(hostname: hostname, id: queryID),
                  let response = MagicDNSUDPClient.query(
                      query,
                      serverIPv4: serverIPv4,
                      serverPort: serverPort,
                      timeoutMilliseconds: timeoutMilliseconds
                  )
            else {
                return []
            }
            return MagicDNSMessage.ipv4Addresses(from: response, queryID: queryID)
        }.value
    }
}

enum MagicDNSMessage {
    static func makeAQuery(hostname: String, id: UInt16) -> [UInt8]? {
        let hostname = hostname
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard !hostname.isEmpty,
              hostname.utf8.count <= 253,
              labels.allSatisfy({ (1 ... 63).contains($0.utf8.count) })
        else {
            return nil
        }

        var message: [UInt8] = []
        message.reserveCapacity(18 + hostname.utf8.count)
        message.appendUInt16(id)
        message.appendUInt16(0x0100) // Recursion desired.
        message.appendUInt16(1)
        message.appendUInt16(0)
        message.appendUInt16(0)
        message.appendUInt16(0)
        for label in labels {
            let bytes = Array(label.utf8)
            message.append(UInt8(bytes.count))
            message.append(contentsOf: bytes)
        }
        message.append(0)
        message.appendUInt16(1) // A
        message.appendUInt16(1) // IN
        return message
    }

    static func ipv4Addresses(from message: [UInt8], queryID: UInt16) -> Set<String> {
        guard message.count >= 12 else { return [] }
        var cursor = 0
        guard readUInt16(message, cursor: &cursor) == queryID,
              let flags = readUInt16(message, cursor: &cursor),
              flags & 0x8000 != 0,
              flags & 0x0200 == 0,
              flags & 0x000F == 0,
              let questionCount = readUInt16(message, cursor: &cursor),
              let answerCount = readUInt16(message, cursor: &cursor),
              readUInt16(message, cursor: &cursor) != nil,
              readUInt16(message, cursor: &cursor) != nil
        else {
            return []
        }

        for _ in 0 ..< questionCount {
            guard skipName(message, cursor: &cursor), cursor + 4 <= message.count else {
                return []
            }
            cursor += 4
        }

        var addresses = Set<String>()
        for _ in 0 ..< answerCount {
            guard skipName(message, cursor: &cursor),
                  let type = readUInt16(message, cursor: &cursor),
                  let recordClass = readUInt16(message, cursor: &cursor),
                  cursor + 4 <= message.count
            else {
                return []
            }
            cursor += 4
            guard let length = readUInt16(message, cursor: &cursor),
                  cursor + Int(length) <= message.count
            else {
                return []
            }
            if type == 1, recordClass == 1, length == 4 {
                addresses.insert(
                    "\(message[cursor]).\(message[cursor + 1])."
                        + "\(message[cursor + 2]).\(message[cursor + 3])"
                )
            }
            cursor += Int(length)
        }
        return addresses
    }

    private static func readUInt16(_ message: [UInt8], cursor: inout Int) -> UInt16? {
        guard cursor + 2 <= message.count else { return nil }
        defer { cursor += 2 }
        return UInt16(message[cursor]) << 8 | UInt16(message[cursor + 1])
    }

    private static func skipName(_ message: [UInt8], cursor: inout Int) -> Bool {
        while cursor < message.count {
            let length = message[cursor]
            if length & 0xC0 == 0xC0 {
                guard cursor + 2 <= message.count else { return false }
                cursor += 2
                return true
            }
            guard length & 0xC0 == 0 else { return false }
            cursor += 1
            if length == 0 { return true }
            guard length <= 63, cursor + Int(length) <= message.count else { return false }
            cursor += Int(length)
        }
        return false
    }
}

private enum MagicDNSUDPClient {
    static func query(
        _ message: [UInt8],
        serverIPv4: String,
        serverPort: UInt16,
        timeoutMilliseconds: Int
    ) -> [UInt8]? {
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketDescriptor >= 0 else { return nil }
        defer { Darwin.close(socketDescriptor) }

        let timeout = max(timeoutMilliseconds, 1)
        var receiveTimeout = timeval(
            tv_sec: timeout / 1_000,
            tv_usec: Int32((timeout % 1_000) * 1_000)
        )
        guard Darwin.setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &receiveTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            return nil
        }

        var server = sockaddr_in()
        server.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        server.sin_family = sa_family_t(AF_INET)
        server.sin_port = serverPort.bigEndian
        guard serverIPv4.withCString({
            Darwin.inet_pton(AF_INET, $0, &server.sin_addr)
        }) == 1 else {
            return nil
        }

        let connected = withUnsafePointer(to: &server) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    socketDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard connected == 0 else { return nil }

        let sent = message.withUnsafeBytes { buffer in
            Darwin.send(socketDescriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard sent == message.count else { return nil }

        var response = [UInt8](repeating: 0, count: 4_096)
        let received = response.withUnsafeMutableBytes { buffer in
            Darwin.recv(socketDescriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard received > 0 else { return nil }
        return Array(response.prefix(received))
    }
}

private extension Array where Element == UInt8 {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}

enum MagicDNSOperationalState: Equatable, Sendable {
    case disabled
    case loading
    case ready
    case mismatch(expected: String, resolved: Set<String>)
}
