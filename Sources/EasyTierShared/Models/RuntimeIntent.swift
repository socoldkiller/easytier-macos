import Foundation

public enum RuntimeIntentKind: String, Codable, Equatable, Sendable {
    case hostname
}

public enum RuntimeIntentStatus: String, Codable, Equatable, Sendable {
    case pending
    case applied
    case conflict
    case unreachable
}

public struct RuntimeIntentTarget: Codable, Equatable, Sendable {
    public var networkName: String
    public var instanceID: String?
    public var peerID: String?
    public var recentHostname: String?
    public var recentIPv4: String?
    public var isLocal: Bool

    public init(
        networkName: String,
        instanceID: String?,
        peerID: String? = nil,
        recentHostname: String? = nil,
        recentIPv4: String? = nil,
        isLocal: Bool
    ) {
        self.networkName = networkName
        self.instanceID = instanceID
        self.peerID = peerID
        self.recentHostname = recentHostname
        self.recentIPv4 = recentIPv4
        self.isLocal = isLocal
    }

    var identityKey: String {
        if let instanceID, !instanceID.isEmpty {
            return "\(isLocal ? "local" : "remote"):\(networkName):instance:\(instanceID)"
        }
        if let peerID, !peerID.isEmpty {
            return "\(isLocal ? "local" : "remote"):\(networkName):peer:\(peerID)"
        }
        return "\(isLocal ? "local" : "remote"):\(networkName):host:\(recentHostname ?? ""):\(recentIPv4 ?? "")"
    }
}

public struct RuntimeIntentDesired: Codable, Equatable, Sendable {
    public var hostname: String?
    public var portForwards: [PortForwardConfig]

    public init(
        hostname: String? = nil,
        portForwards: [PortForwardConfig] = []
    ) {
        self.hostname = hostname
        self.portForwards = portForwards
    }
}

public struct RuntimeIntentBase: Codable, Equatable, Sendable {
    public var hostname: String?

    public init(hostname: String? = nil) {
        self.hostname = hostname
    }
}

public struct RuntimeIntent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var target: RuntimeIntentTarget
    public var kind: RuntimeIntentKind
    public var desired: RuntimeIntentDesired
    public var base: RuntimeIntentBase
    public var status: RuntimeIntentStatus
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        target: RuntimeIntentTarget,
        kind: RuntimeIntentKind,
        desired: RuntimeIntentDesired,
        base: RuntimeIntentBase,
        status: RuntimeIntentStatus = .pending,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.target = target
        self.kind = kind
        self.desired = desired
        self.base = base
        self.status = status
        self.updatedAt = updatedAt
    }

    var reconcileKey: String {
        "\(kind.rawValue):\(target.identityKey)"
    }
}

public extension PortForwardConfig {
    static func fingerprint(_ portForwards: [PortForwardConfig]) -> String {
        portForwards
            .map(\.fingerprintKey)
            .sorted()
            .joined(separator: "\n")
    }

    var fingerprintKey: String {
        [
            proto.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            bind_ip.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            String(bind_port),
            dst_ip.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            String(dst_port),
        ].joined(separator: "|")
    }
}
