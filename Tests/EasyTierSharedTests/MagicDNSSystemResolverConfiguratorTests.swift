import Foundation
import Testing
@testable import EasyTierShared

@Test func magicDNSResolverRefreshesSystemCacheAfterApply() throws {
    let directory = temporaryMagicDNSResolverDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let refresher = RecordingMagicDNSCacheRefresher()
    let configurator = MagicDNSSystemResolverConfigurator(
        resolverDirectory: directory,
        cacheRefresher: refresher
    )

    try configurator.apply(try MagicDNSSystemResolverConfiguration(dnsSuffix: "et.local"))

    #expect(refresher.refreshCount == 1)
    #expect(FileManager.default.fileExists(atPath: directory.appending(path: "et.local").path))
    #expect(FileManager.default.fileExists(atPath: directory.appending(path: "search.easytier").path))
}

@Test func magicDNSResolverRefreshesSystemCacheAfterRemovingManagedFiles() throws {
    let directory = temporaryMagicDNSResolverDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("# Added by easytier\ndomain et.local\n".utf8)
        .write(to: directory.appending(path: "et.local"))
    try Data("nameserver 8.8.8.8\n".utf8)
        .write(to: directory.appending(path: "example.com"))
    let refresher = RecordingMagicDNSCacheRefresher()
    let configurator = MagicDNSSystemResolverConfigurator(
        resolverDirectory: directory,
        cacheRefresher: refresher
    )

    try configurator.removeManagedResolverFiles()

    #expect(refresher.refreshCount == 1)
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "et.local").path))
    #expect(FileManager.default.fileExists(atPath: directory.appending(path: "example.com").path))
}

@Test func magicDNSResolverPropagatesCacheRefreshFailure() throws {
    let directory = temporaryMagicDNSResolverDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let refresher = RecordingMagicDNSCacheRefresher(error: CacheRefreshTestError.expected)
    let configurator = MagicDNSSystemResolverConfigurator(
        resolverDirectory: directory,
        cacheRefresher: refresher
    )

    #expect(throws: CacheRefreshTestError.self) {
        try configurator.apply(try MagicDNSSystemResolverConfiguration(dnsSuffix: "et.local"))
    }

    #expect(refresher.refreshCount == 1)
    #expect(FileManager.default.fileExists(atPath: directory.appending(path: "et.local").path))
}

private func temporaryMagicDNSResolverDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "MagicDNSSystemResolverConfiguratorTests", directoryHint: .isDirectory)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
}

private enum CacheRefreshTestError: Error {
    case expected
}

private final class RecordingMagicDNSCacheRefresher: MagicDNSCacheRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRefreshCount = 0
    private let error: (any Error)?

    init(error: (any Error)? = nil) {
        self.error = error
    }

    var refreshCount: Int {
        lock.withLock { storedRefreshCount }
    }

    func refresh() throws {
        lock.withLock {
            storedRefreshCount += 1
        }
        if let error {
            throw error
        }
    }
}
