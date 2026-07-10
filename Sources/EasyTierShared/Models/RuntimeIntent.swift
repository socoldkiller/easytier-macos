import Foundation

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

public struct RuntimeIntent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var target: RuntimeIntentTarget
    public var desiredHostname: String
    public var baseHostname: String?
    public var status: RuntimeIntentStatus
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        target: RuntimeIntentTarget,
        desiredHostname: String,
        baseHostname: String?,
        status: RuntimeIntentStatus = .pending,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.target = target
        self.desiredHostname = desiredHostname
        self.baseHostname = baseHostname
        self.status = status
        self.updatedAt = updatedAt
    }

    var reconcileKey: String {
        "hostname:\(target.identityKey)"
    }
}
