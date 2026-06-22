import CryptoKit
import Foundation

public struct EasyTierUpdateManifest: Decodable, Equatable, Sendable {
    public var schemaVersion: Int
    public var channel: String
    public var version: String
    public var build: String
    public var tag: String
    public var minimumSystemVersion: String
    public var releaseNotesURL: URL
    public var assets: [String: EasyTierUpdateAsset]

    public init(
        schemaVersion: Int,
        channel: String,
        version: String,
        build: String,
        tag: String,
        minimumSystemVersion: String,
        releaseNotesURL: URL,
        assets: [String: EasyTierUpdateAsset]
    ) {
        self.schemaVersion = schemaVersion
        self.channel = channel
        self.version = version
        self.build = build
        self.tag = tag
        self.minimumSystemVersion = minimumSystemVersion
        self.releaseNotesURL = releaseNotesURL
        self.assets = assets
    }
}

public struct EasyTierUpdateAsset: Decodable, Equatable, Sendable {
    public var url: URL
    public var sha256: String
    public var size: Int64

    public init(url: URL, sha256: String, size: Int64) {
        self.url = url
        self.sha256 = sha256
        self.size = size
    }
}

public struct EasyTierAvailableUpdate: Equatable, Sendable {
    public var version: String
    public var build: String
    public var tag: String
    public var releaseNotesURL: URL
    public var architecture: String
    public var asset: EasyTierUpdateAsset

    public init(
        version: String,
        build: String,
        tag: String,
        releaseNotesURL: URL,
        architecture: String,
        asset: EasyTierUpdateAsset
    ) {
        self.version = version
        self.build = build
        self.tag = tag
        self.releaseNotesURL = releaseNotesURL
        self.architecture = architecture
        self.asset = asset
    }
}

public enum EasyTierUpdateSelectionError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchema(Int)
    case unsupportedChannel(String)
    case unsupportedSystem(required: String, current: String)
    case missingAsset(architecture: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let schema):
            "Unsupported update feed schema: \(schema)."
        case .unsupportedChannel(let channel):
            "Unsupported update channel: \(channel)."
        case .unsupportedSystem(let required, let current):
            "This update requires macOS \(required) or later. This Mac is running \(current)."
        case .missingAsset(let architecture):
            "No update download is available for \(architecture)."
        }
    }
}

public enum EasyTierUpdateSelector {
    public static let supportedSchemaVersion = 1
    public static let supportedChannel = "stable"

    public static func availableUpdate(
        in manifest: EasyTierUpdateManifest,
        currentVersion: String,
        currentBuild: String,
        currentSystemVersion: String,
        architecture: String
    ) throws -> EasyTierAvailableUpdate? {
        guard manifest.schemaVersion == supportedSchemaVersion else {
            throw EasyTierUpdateSelectionError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.channel == supportedChannel else {
            throw EasyTierUpdateSelectionError.unsupportedChannel(manifest.channel)
        }
        guard !isVersion(manifest.minimumSystemVersion, newerThan: currentSystemVersion) else {
            throw EasyTierUpdateSelectionError.unsupportedSystem(
                required: manifest.minimumSystemVersion,
                current: currentSystemVersion
            )
        }
        guard isRemoteNewer(
            remoteVersion: manifest.version,
            remoteBuild: manifest.build,
            currentVersion: currentVersion,
            currentBuild: currentBuild
        ) else {
            return nil
        }
        guard let asset = manifest.assets[architecture] else {
            throw EasyTierUpdateSelectionError.missingAsset(architecture: architecture)
        }

        return EasyTierAvailableUpdate(
            version: manifest.version,
            build: manifest.build,
            tag: manifest.tag,
            releaseNotesURL: manifest.releaseNotesURL,
            architecture: architecture,
            asset: asset
        )
    }

    public static func isRemoteNewer(
        remoteVersion: String,
        remoteBuild: String,
        currentVersion: String,
        currentBuild: String
    ) -> Bool {
        if let remote = EasyTierSemanticVersion(remoteVersion),
           let current = EasyTierSemanticVersion(currentVersion)
        {
            if remote != current { return remote > current }
            return compareBuilds(remoteBuild: remoteBuild, currentBuild: currentBuild)
        }

        return compareBuilds(remoteBuild: remoteBuild, currentBuild: currentBuild)
    }

    private static func isVersion(_ first: String, newerThan second: String) -> Bool {
        guard let lhs = EasyTierSemanticVersion(first), let rhs = EasyTierSemanticVersion(second) else { return false }
        return lhs > rhs
    }

    private static func compareBuilds(remoteBuild: String, currentBuild: String) -> Bool {
        guard let remote = numericBuild(remoteBuild) else {
            return false
        }
        guard let current = numericBuild(currentBuild) else {
            return true
        }
        return remote > current
    }

    private static func numericBuild(_ value: String) -> Int64? {
        Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public struct EasyTierSemanticVersion: Comparable, Equatable, Sendable {
    private var components: [Int]

    public init?(_ rawValue: String) {
        var normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("v") || normalized.hasPrefix("V") {
            normalized.removeFirst()
        }
        normalized = normalized.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? normalized

        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var parsed: [Int] = []
        for part in parts {
            guard !part.isEmpty, let number = Int(part), number >= 0 else { return nil }
            parsed.append(number)
        }
        while parsed.count < 3 { parsed.append(0) }
        components = parsed
    }

    public static func < (lhs: EasyTierSemanticVersion, rhs: EasyTierSemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

public enum EasyTierSHA256 {
    public static func hexDigest(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func file(_ fileURL: URL, matches expectedHexDigest: String) throws -> Bool {
        try hexDigest(for: fileURL).caseInsensitiveCompare(expectedHexDigest) == .orderedSame
    }
}
