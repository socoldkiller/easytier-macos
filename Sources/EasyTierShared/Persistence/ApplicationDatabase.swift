import Darwin
import Foundation
import GRDB

package actor ApplicationDatabase {
    package let databaseURL: URL

    private let legacyBaseDirectory: URL
    private let legacyGatewayURL: URL
    private let networkSecretStore: any NetworkSecretStore
    private var databaseQueue: DatabaseQueue?
    private var isPrepared = false
    private var skipsLegacyImport = false

    package init(
        databaseURL: URL,
        legacyBaseDirectory: URL,
        legacyGatewayURL: URL,
        networkSecretStore: any NetworkSecretStore
    ) {
        self.databaseURL = databaseURL
        self.legacyBaseDirectory = legacyBaseDirectory
        self.legacyGatewayURL = legacyGatewayURL
        self.networkSecretStore = networkSecretStore
    }

    package init(
        baseDirectory: URL = EasyTierStorage.default.baseDirectory,
        gatewayFileURL: URL = GatewayConfigurationStore.defaultFileURL(),
        networkSecretStore: any NetworkSecretStore
    ) {
        databaseURL = baseDirectory.appending(path: "easytier.sqlite3")
        legacyBaseDirectory = baseDirectory
        legacyGatewayURL = gatewayFileURL
        self.networkSecretStore = networkSecretStore
    }

    package func loadWorkspace() async throws -> WorkspacePersistenceState {
        let queue = try await preparedQueue()
        let snapshot = try await queue.read { db in
            guard let settings = try WorkspaceSettingsRecord.fetchOne(db, key: 1) else {
                throw ApplicationDatabaseError.invalidStoredData("Workspace settings are missing.")
            }
            return try WorkspaceDatabaseSnapshot(
                settings: settings,
                configs: NetworkConfigRecord.fetchAll(db),
                runtimeIntents: RuntimeIntentRecord.fetchAll(db),
                fingerprints: ReversedPortForwardFingerprintRecord.fetchAll(db),
                subscriptions: PeerSubscriptionRecord.fetchAll(db),
                cards: PeerCardRecord.fetchAll(db),
                cardURLs: PeerCardURLRecord.fetchAll(db)
            )
        }
        return try WorkspacePersistenceMapper.state(from: snapshot)
    }

    package func saveWorkspace(_ state: WorkspacePersistenceState) async throws {
        let snapshot = try WorkspacePersistenceMapper.records(from: state)
        let queue = try await preparedQueue()
        try await queue.write { db in
            try Self.writeWorkspace(snapshot, to: db)
        }
        repairDatabaseFilePermissions()
    }

    package func loadGateway() async throws -> GatewayPersistedState? {
        let queue = try await preparedQueue()
        guard let record = try await queue.read({ db in
            try GatewayStateRecord.fetchOne(db, key: 1)
        }) else { return nil }
        guard record.payloadVersion == 1 else {
            throw ApplicationDatabaseError.unsupportedPayloadVersion(
                table: GatewayStateRecord.databaseTableName,
                version: record.payloadVersion
            )
        }
        let state = try PersistenceCoding.decode(GatewayPersistedState.self, from: record.jsonPayload)
        guard state.configurationID == record.configurationID,
              state.revision <= UInt64(Int64.max),
              Int64(state.revision) == record.revision
        else {
            throw ApplicationDatabaseError.invalidStoredData("Gateway identity columns do not match its payload.")
        }
        return try GatewayPublishedServicesValidator.validate(state)
    }

    package func saveGateway(_ state: GatewayPersistedState) async throws {
        let normalized = try GatewayPublishedServicesValidator.validate(state)
        let record = try Self.gatewayRecord(from: normalized)
        let queue = try await preparedQueue()
        try await queue.write { db in
            try GatewayStateRecord.deleteAll(db)
            try record.insert(db)
        }
        repairDatabaseFilePermissions()
    }

    package func loadRemoteAccounts() async throws -> [StoredRemoteAccount] {
        let queue = try await preparedQueue()
        let records = try await queue.read { db in
            try RemoteAccountRecord.fetchAll(db)
        }
        return try records
            .map(Self.decodeRemoteAccountRecord)
            .sorted { lhs, rhs in lhs.updatedAt > rhs.updatedAt }
    }

    @discardableResult
    package func upsertRemoteAccount(_ proposedAccount: StoredRemoteAccount) async throws -> StoredRemoteAccount {
        let queue = try await preparedQueue()
        let account = try await queue.write { db in
            var account = proposedAccount
            if let existing = try RemoteAccountRecord
                .filter(Column("controlOrigin") == account.profile.controlOrigin.absoluteString)
                .filter(Column("username") == account.profile.username)
                .fetchOne(db),
               existing.id != account.id.rawValue.uuidString.lowercased()
            {
                account.id = RemoteAccountID(
                    UUID(uuidString: existing.id) ?? account.id.rawValue
                )
                account.createdAt = try Self.decodeRemoteAccountRecord(existing).createdAt
            }
            let record = try Self.remoteAccountRecord(from: account)
            try record.save(db)
            return account
        }
        repairDatabaseFilePermissions()
        return account
    }

    static func decodeRemoteAccountRecord(_ record: RemoteAccountRecord) throws -> StoredRemoteAccount {
        guard record.payloadVersion == 1 else {
            throw ApplicationDatabaseError.unsupportedPayloadVersion(
                table: RemoteAccountRecord.databaseTableName,
                version: record.payloadVersion
            )
        }
        let account = try PersistenceCoding.decode(StoredRemoteAccount.self, from: record.jsonPayload)
        guard account.id.rawValue.uuidString.lowercased() == record.id,
              account.profile.controlOrigin.absoluteString == record.controlOrigin,
              account.profile.username == record.username
        else {
            throw ApplicationDatabaseError.invalidStoredData(
                "Remote account identity columns do not match its payload."
            )
        }
        return account
    }

    package func removeRemoteAccount(id: RemoteAccountID) async throws {
        let queue = try await preparedQueue()
        _ = try await queue.write { db in
            try RemoteAccountRecord.deleteOne(db, key: id.rawValue.uuidString.lowercased())
        }
        repairDatabaseFilePermissions()
    }

    private static func remoteAccountRecord(from account: StoredRemoteAccount) throws -> RemoteAccountRecord {
        RemoteAccountRecord(
            id: account.id.rawValue.uuidString.lowercased(),
            controlOrigin: account.profile.controlOrigin.absoluteString,
            username: account.profile.username,
            payloadVersion: 1,
            jsonPayload: try PersistenceCoding.encode(account)
        )
    }

    package func retryPreparation() async throws {
        isPrepared = false
        _ = try await preparedQueue()
    }

    package func rebuildEmptyDatabase() async throws {
        if let databaseQueue {
            try databaseQueue.close()
        }
        databaseQueue = nil
        isPrepared = false

        let recoveryDirectory = legacyBaseDirectory
            .appending(path: "database-recovery", directoryHint: .isDirectory)
            .appending(
                path: "\(Int(Date.now.timeIntervalSince1970))-\(UUID().uuidString.lowercased())",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        try setPermissions(0o700, at: recoveryDirectory)

        for url in databaseFiles() where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.moveItem(
                at: url,
                to: recoveryDirectory.appending(path: url.lastPathComponent)
            )
        }

        skipsLegacyImport = true
        _ = try await preparedQueue()
    }

    private func preparedQueue() async throws -> DatabaseQueue {
        if isPrepared, let databaseQueue { return databaseQueue }

        try FileManager.default.createDirectory(at: legacyBaseDirectory, withIntermediateDirectories: true)
        try setPermissions(0o700, at: legacyBaseDirectory)
        let existedBeforeOpen = FileManager.default.fileExists(atPath: databaseURL.path)

        let queue: DatabaseQueue
        if let databaseQueue {
            queue = databaseQueue
        } else {
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA synchronous = FULL")
                try db.execute(sql: "PRAGMA busy_timeout = 5000")
            }
            queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
            databaseQueue = queue
        }

        if existedBeforeOpen {
            try checkIntegrity(of: queue)
        }

        let migrator = Self.makeMigrator()
        let needsMigration = try await queue.read { db in
            try !migrator.hasCompletedMigrations(db)
        }
        if existedBeforeOpen, needsMigration {
            try createMigrationBackup(from: queue)
        }
        try migrator.migrate(queue)
        try await importLegacyIfNeeded(into: queue)
        try checkIntegrity(of: queue)
        repairDatabaseFilePermissions()
        isPrepared = true
        return queue
    }

    private func importLegacyIfNeeded(into queue: DatabaseQueue) async throws {
        let alreadyImported = try await queue.read { db in
            try PersistenceMetadataRecord.fetchOne(db, key: "legacyImport")?.value == "complete"
        }
        guard !alreadyImported else { return }

        let workspace: WorkspacePersistenceState
        let gateway: GatewayPersistedState?
        if skipsLegacyImport {
            workspace = .defaultState()
            gateway = nil
        } else {
            var legacy = try loadLegacyWorkspace()
            for index in legacy.configs.indices {
                guard let secret = legacy.configs[index].network_secret?.nilIfEmpty else { continue }
                try await networkSecretStore.save(secret, for: legacy.configs[index], purpose: .update)
                legacy.configs[index].network_secret = nil
            }
            workspace = legacy
            gateway = try loadLegacyGateway()
        }

        let workspaceSnapshot = try WorkspacePersistenceMapper.records(from: workspace)
        let gatewayRecord = try gateway.map(Self.gatewayRecord(from:))
        try await queue.write { db in
            try Self.writeWorkspace(workspaceSnapshot, to: db)
            try GatewayStateRecord.deleteAll(db)
            if let gatewayRecord {
                try gatewayRecord.insert(db)
            }
            try PersistenceMetadataRecord(key: "legacyImport", value: "complete").insert(db)
        }
        skipsLegacyImport = false
    }

    private func loadLegacyWorkspace() throws -> WorkspacePersistenceState {
        let stateURL = legacyBaseDirectory.appending(path: "state.json")
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return .defaultState()
        }

        let snapshot = try JSONDecoder().decode(AppSnapshot.self, from: Data(contentsOf: stateURL))
        let configs = try snapshot.configIDs.map { id in
            let url = legacyBaseDirectory.appending(path: "configs/\(id).toml")
            return try NetworkConfigTOMLCodec.decode(String(contentsOf: url, encoding: .utf8))
        }
        return WorkspacePersistenceState(
            configs: configs,
            selectedConfigID: snapshot.lastSelectedConfigID,
            mode: snapshot.mode,
            vpnOnDemandEnabled: snapshot.vpnOnDemandEnabled,
            runtimeIntents: snapshot.runtimeIntents,
            reversedPortForwardFingerprints: snapshot.reversedPortForwardFingerprints,
            magicDNSSettings: snapshot.magicDNSSettings,
            peerSubscriptions: snapshot.peerSubscriptions
        )
    }

    private func loadLegacyGateway() throws -> GatewayPersistedState? {
        guard FileManager.default.fileExists(atPath: legacyGatewayURL.path) else { return nil }
        let state = try JSONDecoder().decode(
            GatewayPersistedState.self,
            from: Data(contentsOf: legacyGatewayURL)
        )
        return try GatewayPublishedServicesValidator.validate(state)
    }

    private static func writeWorkspace(_ snapshot: WorkspaceDatabaseSnapshot, to db: Database) throws {
        try PeerCardURLRecord.deleteAll(db)
        try PeerCardRecord.deleteAll(db)
        try PeerSubscriptionRecord.deleteAll(db)
        try ReversedPortForwardFingerprintRecord.deleteAll(db)
        try RuntimeIntentRecord.deleteAll(db)
        try WorkspaceSettingsRecord.deleteAll(db)
        try NetworkConfigRecord.deleteAll(db)

        for record in snapshot.configs { try record.insert(db) }
        try snapshot.settings.insert(db)
        for record in snapshot.runtimeIntents { try record.insert(db) }
        for record in snapshot.fingerprints { try record.insert(db) }
        for record in snapshot.subscriptions { try record.insert(db) }
        for record in snapshot.cards { try record.insert(db) }
        for record in snapshot.cardURLs { try record.insert(db) }
    }

    private static func gatewayRecord(from state: GatewayPersistedState) throws -> GatewayStateRecord {
        guard state.revision <= UInt64(Int64.max) else {
            throw ApplicationDatabaseError.invalidStoredData("Gateway revision exceeds SQLite integer range.")
        }
        return GatewayStateRecord(
            configurationID: state.configurationID,
            revision: Int64(state.revision),
            payloadVersion: 1,
            jsonPayload: try PersistenceCoding.encode(state)
        )
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createApplicationDatabaseV1") { db in
            try db.create(table: PersistenceMetadataRecord.databaseTableName) { table in
                table.column("key", .text).primaryKey()
                table.column("value", .text).notNull()
            }
            try db.create(table: NetworkConfigRecord.databaseTableName) { table in
                table.column("id", .text).primaryKey()
                table.column("position", .integer).notNull().check { $0 >= 0 }
                table.column("payloadVersion", .integer).notNull()
                table.column("tomlPayload", .text).notNull()
            }
            try db.create(table: WorkspaceSettingsRecord.databaseTableName) { table in
                table.column("id", .integer).primaryKey().check { $0 == 1 }
                table.column("selectedConfigID", .text)
                    .references(NetworkConfigRecord.databaseTableName, onDelete: .setNull)
                table.column("rpcListenEnabled", .boolean).notNull()
                table.column("rpcListenPort", .integer).notNull()
                table.column("rpcPortalWhitelistJSON", .text).notNull()
                table.column("vpnOnDemandEnabled", .boolean).notNull()
                table.column("magicDNSSuffix", .text).notNull()
            }
            try db.create(table: RuntimeIntentRecord.databaseTableName) { table in
                table.column("id", .text).primaryKey()
                table.column("position", .integer).notNull().check { $0 >= 0 }
                table.column("networkName", .text).notNull()
                table.column("instanceID", .text)
                table.column("peerID", .text)
                table.column("recentHostname", .text)
                table.column("recentIPv4", .text)
                table.column("isLocal", .boolean).notNull()
                table.column("desiredHostname", .text).notNull()
                table.column("baseHostname", .text)
                table.column("status", .text).notNull()
                table.column("updatedAt", .double).notNull()
            }
            try db.create(table: ReversedPortForwardFingerprintRecord.databaseTableName) { table in
                table.column("configID", .text).notNull()
                    .references(NetworkConfigRecord.databaseTableName, onDelete: .cascade)
                table.column("fingerprint", .text).notNull()
                table.primaryKey(["configID", "fingerprint"])
            }
            try db.create(table: PeerSubscriptionRecord.databaseTableName) { table in
                table.column("id", .text).primaryKey()
                table.column("position", .integer).notNull().check { $0 >= 0 }
                table.column("name", .text).notNull()
                table.column("subscriptionURL", .text)
                table.column("lastFetchedAt", .double)
            }
            try db.create(table: PeerCardRecord.databaseTableName) { table in
                table.column("subscriptionID", .text).notNull()
                    .references(PeerSubscriptionRecord.databaseTableName, onDelete: .cascade)
                table.column("id", .text).notNull()
                table.column("position", .integer).notNull().check { $0 >= 0 }
                table.column("name", .text).notNull()
                table.column("proto", .text).notNull()
                table.column("note", .text)
                table.primaryKey(["subscriptionID", "id"])
            }
            try db.create(table: PeerCardURLRecord.databaseTableName) { table in
                table.column("subscriptionID", .text).notNull()
                table.column("cardID", .text).notNull()
                table.column("position", .integer).notNull().check { $0 >= 0 }
                table.column("url", .text).notNull()
                table.primaryKey(["subscriptionID", "cardID", "position"])
                table.foreignKey(
                    ["subscriptionID", "cardID"],
                    references: PeerCardRecord.databaseTableName,
                    columns: ["subscriptionID", "id"],
                    onDelete: .cascade
                )
            }
            try db.create(table: GatewayStateRecord.databaseTableName) { table in
                table.column("id", .integer).primaryKey().check { $0 == 1 }
                table.column("configurationID", .text).notNull()
                table.column("revision", .integer).notNull()
                table.column("payloadVersion", .integer).notNull()
                table.column("jsonPayload", .text).notNull()
            }
        }
        migrator.registerMigration("createRemoteAccounts") { db in
            if try db.tableExists(RemoteAccountRecord.databaseTableName) {
                try db.drop(table: RemoteAccountRecord.databaseTableName)
            }
            try db.create(table: RemoteAccountRecord.databaseTableName) { table in
                table.column("id", .text).primaryKey()
                table.column("controlOrigin", .text).notNull()
                table.column("username", .text).notNull()
                table.column("payloadVersion", .integer).notNull()
                table.column("jsonPayload", .text).notNull()
                table.uniqueKey(["controlOrigin", "username"])
            }
        }
        return migrator
    }

    private func checkIntegrity(of queue: DatabaseQueue) throws {
        let results = try queue.read { db in
            try String.fetchAll(db, sql: "PRAGMA quick_check")
        }
        guard results == ["ok"] else {
            throw ApplicationDatabaseError.integrityCheckFailed(
                results.isEmpty ? "No result returned." : results.joined(separator: "; ")
            )
        }
    }

    private func createMigrationBackup(from source: DatabaseQueue) throws {
        let directory = legacyBaseDirectory.appending(path: "database-backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try setPermissions(0o700, at: directory)
        let backupURL = directory.appending(
            path: "easytier-\(Int(Date.now.timeIntervalSince1970))-\(UUID().uuidString.lowercased()).sqlite3"
        )
        let destination = try DatabaseQueue(path: backupURL.path)
        try source.backup(to: destination)
        try destination.close()
        try setPermissions(0o600, at: backupURL)

        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "sqlite3" }
        .sorted { left, right in
            let leftDate = try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let rightDate = try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (leftDate ?? .distantPast) > (rightDate ?? .distantPast)
        }
        for expired in backups.dropFirst(3) {
            try FileManager.default.removeItem(at: expired)
        }
    }

    private func repairDatabaseFilePermissions() {
        for url in [legacyBaseDirectory] + databaseFiles() where FileManager.default.fileExists(atPath: url.path) {
            try? setPermissions(url == legacyBaseDirectory ? 0o700 : 0o600, at: url)
            repairOriginalUserOwnership(for: url)
        }
    }

    private func databaseFiles() -> [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
    }

    private func setPermissions(_ permissions: mode_t, at url: URL) throws {
        guard chmod(url.path, permissions) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func repairOriginalUserOwnership(for url: URL) {
        guard let uidString = ProcessInfo.processInfo.environment["EASYTIER_ORIGINAL_UID"],
              let gidString = ProcessInfo.processInfo.environment["EASYTIER_ORIGINAL_GID"],
              let uid = uid_t(uidString),
              let gid = gid_t(gidString)
        else { return }
        _ = chown(url.path, uid, gid)
    }
}
