import Darwin
import Foundation

public struct EasyTierStorage: Sendable {
    public var baseDirectory: URL
    public var legacyBaseDirectories: [URL]

    public static let `default` = EasyTierStorage(
        baseDirectory: defaultBaseDirectory(),
        legacyBaseDirectories: defaultLegacyBaseDirectories()
    )

    public init(baseDirectory: URL, legacyBaseDirectories: [URL] = []) {
        self.baseDirectory = baseDirectory
        self.legacyBaseDirectories = legacyBaseDirectories
    }

    public func load() throws -> AppSnapshot {
        let url = stateURL(in: baseDirectory)
        if FileManager.default.fileExists(atPath: url.path) {
            return try loadSnapshot(from: url)
        }
        if let legacySnapshot = try loadLegacySnapshot() {
            return legacySnapshot
        }
        return AppSnapshot(configs: [], mode: nil, lastSelectedConfigID: nil)
    }

    public func save(_ snapshot: AppSnapshot) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        let stateURL = stateURL(in: baseDirectory)
        try data.write(to: stateURL, options: .atomic)
        repairOriginalUserOwnership(for: baseDirectory)
        repairOriginalUserOwnership(for: stateURL)
    }

    static func defaultBaseDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        appSupportDirectory(environment: environment)
            .appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }

    static func defaultLegacyBaseDirectories(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let appSupport = appSupportDirectory(environment: environment)
        return legacyAppSupportDirectoryNames.map { name in
            appSupport.appendingPathComponent(name, isDirectory: true)
        }
    }

    private static func appSupportDirectory(environment: [String: String]) -> URL {
        if let originalHome = environment["EASYTIER_ORIGINAL_HOME"], !originalHome.isEmpty {
            return URL(fileURLWithPath: originalHome, isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private func loadLegacySnapshot() throws -> AppSnapshot? {
        var firstError: Error?

        for legacyBaseDirectory in legacyBaseDirectories {
            let url = stateURL(in: legacyBaseDirectory)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let snapshot = try loadSnapshot(from: url)
                try? save(snapshot)
                return snapshot
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if let firstError { throw firstError }
        return nil
    }

    private func loadSnapshot(from url: URL) throws -> AppSnapshot {
        let data = try Data(contentsOf: url)
        return try decoder.decode(AppSnapshot.self, from: data)
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
    // Older builds used these names; on case-insensitive volumes, "EasyTier" can
    // also resolve to EasyTier Core's legacy "easytier" runtime directory.
    private static let legacyAppSupportDirectoryNames = ["EasyTier", "easytier", "com.kkrainbow.easytier"]
}
