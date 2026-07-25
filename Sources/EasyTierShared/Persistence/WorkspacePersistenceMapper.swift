import Foundation

enum WorkspacePersistenceMapper {
    static func records(from state: WorkspacePersistenceState) throws -> WorkspaceDatabaseSnapshot {
        try validate(state)

        let settings = WorkspaceSettingsRecord(
            selectedConfigID: state.selectedConfigID,
            rpcListenEnabled: state.mode.rpcListenEnabled,
            rpcListenPort: state.mode.rpcListenPort,
            rpcPortalWhitelistJSON: try PersistenceCoding.encode(state.mode.rpcPortalWhitelist),
            vpnOnDemandEnabled: state.vpnOnDemandEnabled,
            magicDNSSuffix: state.magicDNSSettings.dnsSuffix
        )

        let configs = try state.configs.enumerated().map { position, config in
            var sanitized = config
            sanitized.network_secret = nil
            return NetworkConfigRecord(
                id: sanitized.id,
                position: position,
                payloadVersion: 1,
                tomlPayload: try NetworkConfigTOMLCodec.encode(sanitized, mode: .export)
            )
        }

        let intents = state.runtimeIntents.enumerated().map { position, intent in
            RuntimeIntentRecord(
                id: intent.id,
                position: position,
                networkName: intent.target.networkName,
                instanceID: intent.target.instanceID,
                peerID: intent.target.peerID,
                recentHostname: intent.target.recentHostname,
                recentIPv4: intent.target.recentIPv4,
                isLocal: intent.target.isLocal,
                desiredHostname: intent.desiredHostname,
                baseHostname: intent.baseHostname,
                status: intent.status.rawValue,
                updatedAt: intent.updatedAt.timeIntervalSince1970
            )
        }

        let fingerprints = state.reversedPortForwardFingerprints.flatMap { configID, values in
            values.sorted().map {
                ReversedPortForwardFingerprintRecord(configID: configID, fingerprint: $0)
            }
        }

        var subscriptionRecords: [PeerSubscriptionRecord] = []
        var cardRecords: [PeerCardRecord] = []
        var urlRecords: [PeerCardURLRecord] = []
        for (subscriptionPosition, subscription) in state.peerSubscriptions.enumerated() {
            subscriptionRecords.append(PeerSubscriptionRecord(
                id: subscription.id,
                position: subscriptionPosition,
                name: subscription.name,
                subscriptionURL: subscription.subscriptionURL?.absoluteString,
                lastFetchedAt: subscription.lastFetchedAt?.timeIntervalSince1970
            ))
            for (cardPosition, card) in subscription.cards.enumerated() {
                cardRecords.append(PeerCardRecord(
                    subscriptionID: subscription.id,
                    id: card.id,
                    position: cardPosition,
                    name: card.name,
                    proto: card.proto,
                    note: card.note
                ))
                for (urlPosition, url) in card.urls.enumerated() {
                    urlRecords.append(PeerCardURLRecord(
                        subscriptionID: subscription.id,
                        cardID: card.id,
                        position: urlPosition,
                        url: url
                    ))
                }
            }
        }

        return WorkspaceDatabaseSnapshot(
            settings: settings,
            configs: configs,
            runtimeIntents: intents,
            fingerprints: fingerprints,
            subscriptions: subscriptionRecords,
            cards: cardRecords,
            cardURLs: urlRecords
        )
    }

    static func state(from snapshot: WorkspaceDatabaseSnapshot) throws -> WorkspacePersistenceState {
        let configs = try snapshot.configs
            .sorted(by: positionOrder)
            .map { record in
                guard record.payloadVersion == 1 else {
                    throw ApplicationDatabaseError.unsupportedPayloadVersion(
                        table: NetworkConfigRecord.databaseTableName,
                        version: record.payloadVersion
                    )
                }
                var config = try NetworkConfigTOMLCodec.decode(record.tomlPayload)
                guard config.id == record.id else {
                    throw ApplicationDatabaseError.invalidStoredData(
                        "Network configuration row \(record.id) contains payload for \(config.id)."
                    )
                }
                config.network_secret = nil
                return config
            }

        let mode = AppMode(
            rpcListenEnabled: snapshot.settings.rpcListenEnabled,
            rpcListenPort: snapshot.settings.rpcListenPort,
            rpcPortalWhitelist: try PersistenceCoding.decode(
                Optional<[String]>.self,
                from: snapshot.settings.rpcPortalWhitelistJSON
            )
        )
        let magicDNSSettings = try MagicDNSSettings(dnsSuffix: snapshot.settings.magicDNSSuffix)
        let intents = try snapshot.runtimeIntents
            .sorted(by: positionOrder)
            .map { record in
                guard let status = RuntimeIntentStatus(rawValue: record.status) else {
                    throw ApplicationDatabaseError.invalidStoredData(
                        "Runtime intent \(record.id) has invalid status \(record.status)."
                    )
                }
                return RuntimeIntent(
                    id: record.id,
                    target: RuntimeIntentTarget(
                        networkName: record.networkName,
                        instanceID: record.instanceID,
                        peerID: record.peerID,
                        recentHostname: record.recentHostname,
                        recentIPv4: record.recentIPv4,
                        isLocal: record.isLocal
                    ),
                    desiredHostname: record.desiredHostname,
                    baseHostname: record.baseHostname,
                    status: status,
                    updatedAt: Date(timeIntervalSince1970: record.updatedAt)
                )
            }

        let fingerprints = Dictionary(grouping: snapshot.fingerprints, by: \.configID)
            .mapValues { Set($0.map(\.fingerprint)) }

        let cardsBySubscription = Dictionary(grouping: snapshot.cards, by: \.subscriptionID)
        let urlsByCard = Dictionary(grouping: snapshot.cardURLs) {
            PeerCardKey(subscriptionID: $0.subscriptionID, cardID: $0.cardID)
        }
        let subscriptions = snapshot.subscriptions.sorted(by: positionOrder).map { subscription in
            let cards = (cardsBySubscription[subscription.id] ?? []).sorted(by: positionOrder).map { card in
                let key = PeerCardKey(subscriptionID: card.subscriptionID, cardID: card.id)
                let urls = (urlsByCard[key] ?? []).sorted(by: positionOrder).map(\.url)
                return PeerCard(id: card.id, name: card.name, proto: card.proto, urls: urls, note: card.note)
            }
            return PeerSubscription(
                id: subscription.id,
                name: subscription.name,
                subscriptionURL: subscription.subscriptionURL.flatMap(URL.init(string:)),
                cards: cards,
                lastFetchedAt: subscription.lastFetchedAt.map(Date.init(timeIntervalSince1970:))
            )
        }

        let state = WorkspacePersistenceState(
            configs: configs,
            selectedConfigID: snapshot.settings.selectedConfigID,
            mode: mode,
            vpnOnDemandEnabled: snapshot.settings.vpnOnDemandEnabled,
            runtimeIntents: intents,
            reversedPortForwardFingerprints: fingerprints,
            magicDNSSettings: magicDNSSettings,
            peerSubscriptions: subscriptions
        )
        try validate(state)
        return state
    }

    private static func validate(_ state: WorkspacePersistenceState) throws {
        let configIDs = state.configs.map(\.id)
        guard Set(configIDs).count == configIDs.count else {
            throw ApplicationDatabaseError.invalidStoredData("Network configuration IDs must be unique.")
        }
        if let selectedConfigID = state.selectedConfigID, !configIDs.contains(selectedConfigID) {
            throw ApplicationDatabaseError.invalidStoredData(
                "Selected network configuration \(selectedConfigID) does not exist."
            )
        }
        for config in state.configs where config.network_secret?.nilIfEmpty != nil {
            throw ApplicationDatabaseError.secretInDatabasePayload(config.id)
        }
        let invalidFingerprintID = state.reversedPortForwardFingerprints.keys.first {
            !configIDs.contains($0)
        }
        if let invalidFingerprintID {
            throw ApplicationDatabaseError.invalidStoredData(
                "Reversed port-forward state references missing configuration \(invalidFingerprintID)."
            )
        }
    }

    private static func positionOrder<T>(_ lhs: T, _ rhs: T) -> Bool where T: PositionedRecord {
        lhs.position == rhs.position ? lhs.stableID < rhs.stableID : lhs.position < rhs.position
    }
}

private protocol PositionedRecord {
    var position: Int { get }
    var stableID: String { get }
}

extension NetworkConfigRecord: PositionedRecord { var stableID: String { id } }
extension RuntimeIntentRecord: PositionedRecord { var stableID: String { id } }
extension PeerSubscriptionRecord: PositionedRecord { var stableID: String { id } }
extension PeerCardRecord: PositionedRecord { var stableID: String { subscriptionID + ":" + id } }
extension PeerCardURLRecord: PositionedRecord { var stableID: String { subscriptionID + ":" + cardID + ":" + url } }

private struct PeerCardKey: Hashable {
    var subscriptionID: String
    var cardID: String
}
