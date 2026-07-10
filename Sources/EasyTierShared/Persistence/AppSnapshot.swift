import Foundation

public struct AppSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var configIDs: [String]
    public var mode: AppMode
    public var lastSelectedConfigID: String?
    public var vpnOnDemandEnabled: Bool
    public var runtimeIntents: [RuntimeIntent]
    public var reversedPortForwardFingerprints: [String: Set<String>]
    public var magicDNSSettings: MagicDNSSettings
    public var peerSubscriptions: [PeerSubscription]

    public init(
        configIDs: [String],
        mode: AppMode = .default,
        lastSelectedConfigID: String?,
        vpnOnDemandEnabled: Bool = false,
        runtimeIntents: [RuntimeIntent] = [],
        reversedPortForwardFingerprints: [String: Set<String>] = [:],
        magicDNSSettings: MagicDNSSettings = .default,
        peerSubscriptions: [PeerSubscription] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.configIDs = configIDs
        self.mode = mode
        self.lastSelectedConfigID = lastSelectedConfigID
        self.vpnOnDemandEnabled = vpnOnDemandEnabled
        self.runtimeIntents = runtimeIntents
        self.reversedPortForwardFingerprints = reversedPortForwardFingerprints
        self.magicDNSSettings = magicDNSSettings
        self.peerSubscriptions = peerSubscriptions
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case configIDs
        case mode
        case lastSelectedConfigID
        case vpnOnDemandEnabled
        case runtimeIntents
        case reversedPortForwardFingerprints
        case magicDNSSettings
        case peerSubscriptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AppSnapshotDecodingError.unsupportedSchemaVersion(schemaVersion)
        }
        configIDs = try container.decode([String].self, forKey: .configIDs)
        mode = try container.decode(AppMode.self, forKey: .mode)
        lastSelectedConfigID = try container.decodeIfPresent(String.self, forKey: .lastSelectedConfigID)
        vpnOnDemandEnabled = try container.decode(Bool.self, forKey: .vpnOnDemandEnabled)
        runtimeIntents = try container.decode([RuntimeIntent].self, forKey: .runtimeIntents)
        reversedPortForwardFingerprints = try container.decode([String: Set<String>].self, forKey: .reversedPortForwardFingerprints)
        magicDNSSettings = try container.decode(MagicDNSSettings.self, forKey: .magicDNSSettings)
        peerSubscriptions = try container.decode([PeerSubscription].self, forKey: .peerSubscriptions)
    }
}

public enum AppSnapshotDecodingError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Unsupported state schema version \(version); expected \(AppSnapshot.currentSchemaVersion)."
        }
    }
}
