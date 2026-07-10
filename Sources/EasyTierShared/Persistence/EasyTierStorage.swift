import Darwin
import Foundation

public struct EasyTierStorageLoadResult: Sendable {
    public var snapshot: AppSnapshot
    public var configs: [NetworkConfig]
    public var recoveryMessage: String?

    public init(snapshot: AppSnapshot, configs: [NetworkConfig], recoveryMessage: String? = nil) {
        self.snapshot = snapshot
        self.configs = configs
        self.recoveryMessage = recoveryMessage
    }
}

public struct EasyTierStorage: Sendable {
    public var baseDirectory: URL

    public static let `default` = EasyTierStorage(
        baseDirectory: defaultBaseDirectory()
    )

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    public func load() throws -> EasyTierStorageLoadResult {
        let url = stateURL(in: baseDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let state = makeDefaultState()
            try save(state.snapshot, configs: state.configs)
            return state
        }

        let data = try Data(contentsOf: url)
        let snapshot: AppSnapshot
        do {
            snapshot = try decoder.decode(AppSnapshot.self, from: data)
        } catch {
            let backupURL = try backUpIncompatibleState(at: url)
            let state = makeDefaultState()
            try save(state.snapshot, configs: state.configs)
            return EasyTierStorageLoadResult(
                snapshot: state.snapshot,
                configs: state.configs,
                recoveryMessage: "Saved state was incompatible and was backed up to \(backupURL.lastPathComponent). Existing TOML files were preserved; re-import them to restore configurations."
            )
        }

        let configs = try snapshot.configIDs.map { try loadConfig(id: $0) }
        return EasyTierStorageLoadResult(snapshot: snapshot, configs: configs)
    }

    public func save(_ snapshot: AppSnapshot, configs: [NetworkConfig]) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        for config in configs {
            try saveConfig(config)
        }
        let data = try encoder.encode(snapshot)
        let stateURL = stateURL(in: baseDirectory)
        try data.write(to: stateURL, options: .atomic)
        repairOriginalUserOwnership(for: baseDirectory)
        repairOriginalUserOwnership(for: stateURL)
    }

    public func configURL(forID id: String) -> URL {
        baseDirectory.appendingPathComponent("configs/\(id).toml")
    }

    public func loadConfig(id: String) throws -> NetworkConfig {
        let toml = try String(contentsOf: configURL(forID: id), encoding: .utf8)
        return try NetworkConfigTOMLCodec.decode(toml)
    }

    public func saveConfig(_ config: NetworkConfig) throws {
        let url = configURL(forID: config.instance_id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try NetworkConfigTOMLCodec.encode(config).write(to: url, atomically: true, encoding: .utf8)
        repairOriginalUserOwnership(for: url.deletingLastPathComponent())
        repairOriginalUserOwnership(for: url)
    }

    public func deleteConfig(id: String) throws {
        let url = configURL(forID: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func defaultBaseDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        appSupportDirectory(environment: environment)
            .appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }

    private static func appSupportDirectory(environment: [String: String]) -> URL {
        if let originalHome = environment["EASYTIER_ORIGINAL_HOME"], !originalHome.isEmpty {
            return URL(fileURLWithPath: originalHome, isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private func makeDefaultState() -> EasyTierStorageLoadResult {
        let config = NetworkConfig()
        let snapshot = AppSnapshot(configIDs: [config.id], lastSelectedConfigID: config.id)
        return EasyTierStorageLoadResult(snapshot: snapshot, configs: [config])
    }

    private func backUpIncompatibleState(at url: URL) throws -> URL {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let backupURL = baseDirectory.appendingPathComponent("state.incompatible-\(timestamp).json")
        try FileManager.default.moveItem(at: url, to: backupURL)
        repairOriginalUserOwnership(for: backupURL)
        return backupURL
    }

    private func stateURL(in directory: URL) -> URL {
        directory.appendingPathComponent("state.json")
    }

    private func repairOriginalUserOwnership(for url: URL) {
        guard let uidString = ProcessInfo.processInfo.environment["EASYTIER_ORIGINAL_UID"],
              let gidString = ProcessInfo.processInfo.environment["EASYTIER_ORIGINAL_GID"],
              let uid = uid_t(uidString),
              let gid = gid_t(gidString)
        else { return }
        _ = chown(url.path, uid, gid)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder { JSONDecoder() }

    private static let appSupportDirectoryName = "com.kkrainbow.easytier.mac"
}
