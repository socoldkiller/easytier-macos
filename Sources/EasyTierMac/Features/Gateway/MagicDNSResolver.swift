import Darwin
import Foundation

protocol MagicDNSResolving: Sendable {
    func resolveIPv4(hostname: String) async -> Set<String>
}

struct SystemMagicDNSResolver: MagicDNSResolving {
    func resolveIPv4(hostname: String) async -> Set<String> {
        await Task.detached(priority: .utility) {
            var hints = addrinfo(
                ai_flags: AI_ADDRCONFIG,
                ai_family: AF_INET,
                ai_socktype: SOCK_STREAM,
                ai_protocol: IPPROTO_TCP,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(hostname, nil, &hints, &result) == 0, let result else {
                return []
            }
            defer { freeaddrinfo(result) }

            var addresses = Set<String>()
            var current: UnsafeMutablePointer<addrinfo>? = result
            while let info = current {
                defer { current = info.pointee.ai_next }
                guard let address = info.pointee.ai_addr else { continue }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                var value = ipv4
                guard inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil else {
                    continue
                }
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                addresses.insert(String(decoding: bytes, as: UTF8.self))
            }
            return addresses
        }.value
    }
}

enum MagicDNSOperationalState: Equatable, Sendable {
    case disabled
    case loading
    case ready
    case mismatch(expected: String, resolved: Set<String>)
}
