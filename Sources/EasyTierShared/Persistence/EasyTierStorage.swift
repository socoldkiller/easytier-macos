import Darwin
import Foundation

public struct EasyTierStorage: Sendable {
    public var baseDirectory: URL

    public static let `default` = EasyTierStorage(
        baseDirectory: defaultBaseDirectory()
    )

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    public func load() throws -> AppSnapshot {
        let url = stateURL(in: baseDirectory)
        if FileManager.default.fileExists(atPath: url.path) {
            return try loadSnapshot(from: url)
        }
        let snapshot = AppSnapshot(configs: [StoredNetworkConfig(config: NetworkConfig())], mode: nil, lastSelectedConfigID: nil)
        try save(snapshot)
        return snapshot
    }

    public func save(_ snapshot: AppSnapshot) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        for stored in snapshot.configs {
            try saveConfig(stored.config, for: stored)
        }
        let data = try encoder.encode(snapshot)
        let stateURL = stateURL(in: baseDirectory)
        try data.write(to: stateURL, options: .atomic)
        repairOriginalUserOwnership(for: baseDirectory)
        repairOriginalUserOwnership(for: stateURL)
    }

    public func configURL(for stored: StoredNetworkConfig) -> URL {
        baseDirectory.appendingPathComponent(stored.tomlPath)
    }

    public func loadConfig(_ stored: StoredNetworkConfig) throws -> NetworkConfig {
        let toml = try String(contentsOf: configURL(for: stored), encoding: .utf8)
        return try NetworkConfigTOMLCodec.decode(toml)
    }

    public func saveConfig(_ config: NetworkConfig, for stored: StoredNetworkConfig) throws {
        let url = configURL(for: stored)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try NetworkConfigTOMLCodec.encode(config).write(to: url, atomically: true, encoding: .utf8)
        repairOriginalUserOwnership(for: url.deletingLastPathComponent())
        repairOriginalUserOwnership(for: url)
    }

    public func deleteConfig(_ stored: StoredNetworkConfig) throws {
        let url = configURL(for: stored)
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

    private func loadSnapshot(from url: URL) throws -> AppSnapshot {
        let data = try Data(contentsOf: url)
        var snapshot = try decoder.decode(AppSnapshot.self, from: data)
        for index in snapshot.configs.indices {
            snapshot.configs[index].config = try loadConfig(snapshot.configs[index])
        }
        return snapshot
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
