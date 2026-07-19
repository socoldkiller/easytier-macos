import Darwin
import Foundation

package protocol GatewayConfigurationStoring: Sendable {
    func load() async throws -> GatewayPersistedState?
    func save(_ state: GatewayPersistedState) async throws
}

package enum GatewayConfigurationStoreError: LocalizedError, Sendable {
    case incompatibleConfiguration(backupURL: URL, underlyingMessage: String)

    package var errorDescription: String? {
        switch self {
        case let .incompatibleConfiguration(backupURL, underlyingMessage):
            "Gateway configuration was incompatible and was backed up to \(backupURL.lastPathComponent): \(underlyingMessage)"
        }
    }
}

package actor GatewayConfigurationStore: GatewayConfigurationStoring {
    package let fileURL: URL

    package init(fileURL: URL = GatewayConfigurationStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    package func load() throws -> GatewayPersistedState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let state = try JSONDecoder().decode(
                GatewayPersistedState.self,
                from: Data(contentsOf: fileURL)
            )
            return try GatewayPublishedServicesValidator.validate(state)
        } catch {
            let backupURL = try backUpIncompatibleConfiguration()
            throw GatewayConfigurationStoreError.incompatibleConfiguration(
                backupURL: backupURL,
                underlyingMessage: error.localizedDescription
            )
        }
    }

    package func save(_ state: GatewayPersistedState) throws {
        let normalized = try GatewayPublishedServicesValidator.validate(state)

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try setPermissions(0o700, at: directory)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(normalized).write(to: fileURL, options: .atomic)
        try setPermissions(0o600, at: fileURL)
    }

    package static func defaultFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let applicationSupport: URL
        if let originalHome = environment["EASYTIER_ORIGINAL_HOME"], !originalHome.isEmpty {
            applicationSupport = URL(fileURLWithPath: originalHome, isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        } else {
            applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
        }
        return applicationSupport
            .appendingPathComponent("com.kkrainbow.easytier.mac", isDirectory: true)
            .appendingPathComponent("gateway", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    private func backUpIncompatibleConfiguration() throws -> URL {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("config.incompatible-\(timestamp).json")
        try FileManager.default.moveItem(at: fileURL, to: backupURL)
        try setPermissions(0o600, at: backupURL)
        return backupURL
    }

    private func setPermissions(_ permissions: mode_t, at url: URL) throws {
        guard chmod(url.path, permissions) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
