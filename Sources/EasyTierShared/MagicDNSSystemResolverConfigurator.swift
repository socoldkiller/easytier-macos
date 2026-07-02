import Foundation

public struct MagicDNSSystemResolverConfiguration: Equatable, Sendable {
    public var dnsSuffix: String

    public init(dnsSuffix: String) throws {
        self.dnsSuffix = try MagicDNSSettings.normalizedDNSSuffix(dnsSuffix)
    }

    public var resolverFileName: String {
        String(dnsSuffix.dropLast())
    }
}

public struct MagicDNSSystemResolverConfigurator {
    public static let resolverIP = "100.100.100.101"

    private static let resolverFileHeader = "# Added by easytier\n"
    private static let searchResolverFileName = "search.easytier"

    private let resolverDirectory: URL
    private let fileManager: FileManager

    public init(
        resolverDirectory: URL = URL(fileURLWithPath: "/etc/resolver", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.resolverDirectory = resolverDirectory
        self.fileManager = fileManager
    }

    public func apply(from toml: String) throws {
        guard let configuration = try Self.configuration(from: toml) else { return }
        try apply(configuration)
    }

    public static func configuration(from toml: String) throws -> MagicDNSSystemResolverConfiguration? {
        let config = try NetworkConfigTOMLCodec.decode(toml)
        guard config.enable_magic_dns == true else { return nil }

        let metadata = try NetworkConfigTOMLCodec.metadata(from: toml)
        return try MagicDNSSystemResolverConfiguration(
            dnsSuffix: metadata.magicDNSSuffix ?? MagicDNSSettings.defaultDNSSuffix
        )
    }

    public func apply(_ configuration: MagicDNSSystemResolverConfiguration) throws {
        try fileManager.createDirectory(at: resolverDirectory, withIntermediateDirectories: true)

        let resolverName = configuration.resolverFileName
        let keep = Set([resolverName, Self.searchResolverFileName])
        try writeResolverFile(
            named: resolverName,
            content: "\(Self.resolverFileHeader)domain \(resolverName)\nnameserver \(Self.resolverIP)\n"
        )
        try writeResolverFile(
            named: Self.searchResolverFileName,
            content: "\(Self.resolverFileHeader)search \(resolverName)\n"
        )
        try removeStaleManagedResolverFiles(keeping: keep)
    }

    public func removeManagedResolverFiles() throws {
        try removeStaleManagedResolverFiles(keeping: [])
    }

    private func writeResolverFile(named name: String, content: String) throws {
        let url = resolverDirectory.appendingPathComponent(name, isDirectory: false)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    private func removeStaleManagedResolverFiles(keeping keep: Set<String>) throws {
        guard fileManager.fileExists(atPath: resolverDirectory.path) else { return }

        let entries = try fileManager.contentsOfDirectory(
            at: resolverDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for url in entries {
            guard !keep.contains(url.lastPathComponent) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }

            let content = try String(contentsOf: url, encoding: .utf8)
            guard content.hasPrefix(Self.resolverFileHeader) else { continue }
            try fileManager.removeItem(at: url)
        }
    }
}
