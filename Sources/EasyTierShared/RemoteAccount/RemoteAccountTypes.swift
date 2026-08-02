import Foundation

package struct RemoteAccountCredential: Codable, Equatable, Sendable {
    package var endpoint: String
    package var token: String
    package var machineID: UUID
    package var deviceName: String

    package init(endpoint: String, token: String, machineID: UUID, deviceName: String) {
        self.endpoint = endpoint
        self.token = token
        self.machineID = machineID
        self.deviceName = deviceName
    }
}

package struct RemoteAccountCredentialRecord: Codable, Equatable, Sendable {
    package var accountID: RemoteAccountID
    package var credential: RemoteAccountCredential

    package init(accountID: RemoteAccountID, credential: RemoteAccountCredential) {
        self.accountID = accountID
        self.credential = credential
    }
}

package struct RemoteAccountCredentialLibrary: Codable, Equatable, Sendable {
    package static let currentFormatVersion = 1

    package var formatVersion: Int
    package var activeAccountID: RemoteAccountID?
    package var records: [RemoteAccountCredentialRecord]

    package init(
        formatVersion: Int = Self.currentFormatVersion,
        activeAccountID: RemoteAccountID? = nil,
        records: [RemoteAccountCredentialRecord] = []
    ) {
        self.formatVersion = formatVersion
        self.activeAccountID = activeAccountID
        self.records = records
    }

    package func credential(for accountID: RemoteAccountID) -> RemoteAccountCredential? {
        records.first { $0.accountID == accountID }?.credential
    }
}

package struct RemoteRuntimeStatus: Codable, Equatable, Sendable {
    package var activeAccountID: RemoteAccountID?
    package var credentialAccountIDs: [RemoteAccountID]
    package var active: Bool
    package var connected: Bool
    package var lastError: String?

    package init(
        activeAccountID: RemoteAccountID? = nil,
        credentialAccountIDs: [RemoteAccountID] = [],
        active: Bool,
        connected: Bool,
        lastError: String? = nil
    ) {
        self.activeAccountID = activeAccountID
        self.credentialAccountIDs = credentialAccountIDs
        self.active = active
        self.connected = connected
        self.lastError = lastError
    }
}

package struct RemoteConfigServerEvent: Codable, Equatable, Sendable {
    package enum Event: String, Codable, Sendable {
        case runNetworkInstance = "run_network_instance"
        case deleteNetworkInstance = "delete_network_instance"
    }

    package var event: Event
    package var instanceID: String
    package var instanceName: String
    package var networkName: String
    package var magicDNSEnabled: Bool
    package var magicDNSSuffix: String

    enum CodingKeys: String, CodingKey {
        case event
        case instanceID = "instance_id"
        case instanceName = "instance_name"
        case networkName = "network_name"
        case magicDNSEnabled = "magic_dns_enabled"
        case magicDNSSuffix = "magic_dns_suffix"
    }
}
