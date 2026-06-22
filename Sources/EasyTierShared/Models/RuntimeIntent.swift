import Foundation

public enum RuntimeIntentKind: String, Codable, Equatable, Sendable {
    case hostname
    case portForwardSet
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

public struct RuntimeReversePortForwardIntent: Codable, Equatable, Sendable {
    public var targetInstanceID: String?
    public var targetPeerID: String?
    public var bindIP: String
    public var bindPort: Int
    public var recentTargetIPv4: String?
    public var targetPort: Int
    public var proto: String

    public init(
        targetInstanceID: String?,
        targetPeerID: String?,
        bindIP: String,
        bindPort: Int,
        recentTargetIPv4: String? = nil,
        targetPort: Int,
        proto: String
    ) {
        self.targetInstanceID = targetInstanceID
        self.targetPeerID = targetPeerID
        self.bindIP = bindIP
        self.bindPort = bindPort
        self.recentTargetIPv4 = recentTargetIPv4
        self.targetPort = targetPort
        self.proto = proto
    }
}

public struct RuntimeIntentDesired: Codable, Equatable, Sendable {
    public var hostname: String?
    public var portForwards: [PortForwardConfig]
    public var reversePortForwards: [RuntimeReversePortForwardIntent]

    public init(
        hostname: String? = nil,
        portForwards: [PortForwardConfig] = [],
        reversePortForwards: [RuntimeReversePortForwardIntent] = []
    ) {
        self.hostname = hostname
        self.portForwards = portForwards
        self.reversePortForwards = reversePortForwards
    }
}

public struct RuntimeIntentBase: Codable, Equatable, Sendable {
    public var hostname: String?
    public var portForwardFingerprint: String?

    public init(hostname: String? = nil, portForwardFingerprint: String? = nil) {
        self.hostname = hostname
        self.portForwardFingerprint = portForwardFingerprint
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

    public func materializedPortForwards(members: [NetworkMemberStatus]) -> [PortForwardConfig]? {
        guard kind == .portForwardSet else { return nil }

        var forwards = desired.portForwards
        for reverse in desired.reversePortForwards {
            guard let member = members.first(where: { member in
                if let targetInstanceID = reverse.targetInstanceID, member.instanceID == targetInstanceID { return true }
                if let targetPeerID = reverse.targetPeerID, member.peerID == targetPeerID { return true }
                return false
            }), let ip = member.copyableIPv4Address else {
                return nil
            }
            forwards.append(PortForwardConfig(
                bind_ip: reverse.bindIP,
                bind_port: reverse.bindPort,
                dst_ip: ip,
                dst_port: reverse.targetPort,
                proto: reverse.proto
            ))
        }
        return forwards
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

    func matchesReverseMaterialization(_ reverse: RuntimeReversePortForwardIntent) -> Bool {
        guard proto.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == reverse.proto.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              bind_ip.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == reverse.bindIP.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              bind_port == reverse.bindPort,
              dst_port == reverse.targetPort
        else { return false }

        guard let recentTargetIPv4 = reverse.recentTargetIPv4?.trimmingCharacters(in: .whitespacesAndNewlines), !recentTargetIPv4.isEmpty else {
            return true
        }
        return dst_ip.trimmingCharacters(in: .whitespacesAndNewlines) == recentTargetIPv4
    }
}
