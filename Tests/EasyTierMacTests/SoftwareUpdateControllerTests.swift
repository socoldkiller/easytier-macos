import EasyTierShared
import Foundation
import Testing
@testable import EasyTierMac

@MainActor
@Test func manualCheckShowsAvailableAndSkippedVersionsTruthfully() async throws {
    let defaultsFixture = makeUserDefaults()
    let defaults = defaultsFixture.defaults
    defer { defaultsFixture.clear() }

    let service = StaticUpdateService(fetchResult: .success(try makeManifest()))
    let controller = SoftwareUpdateController(
        service: service,
        workspace: RecordingWorkspace(),
        userDefaults: defaults,
        prepareForOpeningUpdate: {}
    )
    controller.setSoftwareUpdateWindowVisible(true)

    await controller.checkForUpdates(origin: .manual).value

    guard case .available(let update, _, let wasPreviouslySkipped) = controller.state else {
        Issue.record("Expected an available update")
        return
    }
    #expect(update.version == "99.0.0")
    #expect(!wasPreviouslySkipped)
    #expect(!controller.hasUnacknowledgedUpdate)
    #expect(controller.lastCheckDate != nil)

    controller.skipAvailableUpdate()

    guard case .available(let skippedUpdate, _, let skipped) = controller.state else {
        Issue.record("Skipping must preserve the truthful available state")
        return
    }
    #expect(skippedUpdate == update)
    #expect(skipped)
    #expect(!controller.hasUnacknowledgedUpdate)

    let nextController = SoftwareUpdateController(
        service: service,
        workspace: RecordingWorkspace(),
        userDefaults: defaults,
        prepareForOpeningUpdate: {}
    )
    await nextController.checkForUpdates(origin: .manual).value

    guard case .available(_, _, let remainedSkipped) = nextController.state else {
        Issue.record("Manual checks must reveal a previously skipped release")
        return
    }
    #expect(remainedSkipped)
    #expect(!nextController.hasUnacknowledgedUpdate)
}

@MainActor
@Test func hiddenManualCheckRaisesBannerWhenUpdateArrives() async throws {
    let defaultsFixture = makeUserDefaults()
    let defaults = defaultsFixture.defaults
    defer { defaultsFixture.clear() }

    let service = DelayedFetchService()
    let controller = SoftwareUpdateController(
        service: service,
        workspace: RecordingWorkspace(),
        userDefaults: defaults,
        prepareForOpeningUpdate: {}
    )
    controller.setSoftwareUpdateWindowVisible(true)

    let task = controller.checkForUpdates(origin: .manual)
    try await service.waitUntilFetchStarts()
    controller.setSoftwareUpdateWindowVisible(false)
    await service.finish(with: try makeManifest())
    await task.value

    #expect(controller.hasUnacknowledgedUpdate)
}

@MainActor
@Test func automaticFailureIsSilentWhileManualFailureIsVisible() async {
    let defaultsFixture = makeUserDefaults()
    let defaults = defaultsFixture.defaults
    defer { defaultsFixture.clear() }

    let service = StaticUpdateService(fetchResult: .failure(TestUpdateError.fetchFailed))
    let controller = SoftwareUpdateController(
        service: service,
        workspace: RecordingWorkspace(),
        userDefaults: defaults,
        prepareForOpeningUpdate: {}
    )
    controller.state = .noUpdate(currentVersion: "0.1.0")

    await controller.checkForUpdates(origin: .automatic).value
    #expect(controller.state == .noUpdate(currentVersion: "0.1.0"))
    #expect(!controller.hasUnacknowledgedUpdateIssue)

    await controller.checkForUpdates(origin: .manual).value
    guard case .failed(let message) = controller.state else {
        Issue.record("Manual failures must be visible")
        return
    }
    #expect(message == TestUpdateError.fetchFailed.errorDescription)
    #expect(controller.hasUnacknowledgedUpdateIssue)

    controller.setSoftwareUpdateWindowVisible(true)
    #expect(!controller.hasUnacknowledgedUpdateIssue)
}

@MainActor
@Test func cancelCheckRestoresStateAndIgnoresLateCompletion() async throws {
    let defaultsFixture = makeUserDefaults()
    let defaults = defaultsFixture.defaults
    defer { defaultsFixture.clear() }

    let service = DelayedFetchService()
    let controller = SoftwareUpdateController(
        service: service,
        workspace: RecordingWorkspace(),
        userDefaults: defaults,
        prepareForOpeningUpdate: {}
    )
    controller.state = .noUpdate(currentVersion: "0.1.0")

    let task = controller.checkForUpdates(origin: .manual)
    try await service.waitUntilFetchStarts()
    controller.cancelCheck()

    #expect(controller.state == .noUpdate(currentVersion: "0.1.0"))

    await service.finish(with: try makeManifest())
    await task.value
    #expect(controller.state == .noUpdate(currentVersion: "0.1.0"))
}

@MainActor
@Test func replacementCheckIgnoresOlderResultAndCleanup() async throws {
    let defaultsFixture = makeUserDefaults()
    let defaults = defaultsFixture.defaults
    defer { defaultsFixture.clear() }

    let service = SequencedFetchService()
    let controller = SoftwareUpdateController(
        service: service,
        workspace: RecordingWorkspace(),
        userDefaults: defaults,
        prepareForOpeningUpdate: {}
    )
    controller.setSoftwareUpdateWindowVisible(true)

    let olderTask = controller.checkForUpdates(origin: .manual)
    try await service.waitUntilFetchCount(1)
    let newerTask = controller.checkForUpdates(origin: .manual)
    try await service.waitUntilFetchCount(2)

    await service.finishFetch(at: 1, with: try makeManifest(version: "100.0.0"))
    await newerTask.value
    guard case .available(let newerUpdate, _, _) = controller.state else {
        Issue.record("Expected the replacement check result")
        return
    }
    #expect(newerUpdate.version == "100.0.0")

    await service.finishFetch(at: 0, with: try makeNoUpdateManifest())
    await olderTask.value
    guard case .available(let retainedUpdate, _, _) = controller.state else {
        Issue.record("The older check must not overwrite the replacement")
        return
    }
    #expect(retainedUpdate.version == "100.0.0")
}

@MainActor
@Test func successfulDownloadOpensAndRevealsVerifiedDMG() async throws {
    let defaultsFixture = makeUserDefaults()
    let defaults = defaultsFixture.defaults
    defer { defaultsFixture.clear() }

    let fileURL = try makeFixtureFile(contents: "verified update")
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let digest = try EasyTierSHA256.hexDigest(for: fileURL)
    let update = try makeUpdate(fileURL: fileURL, sha256: digest)
    defaults.set(update.version, forKey: "EasyTierUpdaterSkippedVersion")
    let service = StaticUpdateService(
        fetchResult: .success(try makeManifest()),
        downloadResult: .success(fileURL)
    )
    let workspace = RecordingWorkspace()
    var preparationCount = 0
    let controller = SoftwareUpdateController(
        service: service,
        workspace: workspace,
        userDefaults: defaults,
        prepareForOpeningUpdate: { preparationCount += 1 }
    )
    controller.state = .available(
        update,
        currentVersion: AppVersionInfo.current.version,
        wasPreviouslySkipped: true
    )

    let task = try #require(controller.downloadAvailableUpdate())
    await task.value

    #expect(controller.state == .downloadComplete(update, fileURL: fileURL))
    #expect(defaults.string(forKey: "EasyTierUpdaterSkippedVersion") == nil)
    #expect(preparationCount == 1)
    #expect(workspace.openedURLs == [fileURL])

    controller.revealDownloadedInFinder()
    #expect(workspace.revealedURLGroups == [[fileURL]])
}

@MainActor
@Test func checksumMismatchNeverOpensDownloadedFile() async throws {
    let defaultsFixture = makeUserDefaults()
    let defaults = defaultsFixture.defaults
    defer { defaultsFixture.clear() }

    let fileURL = try makeFixtureFile(contents: "tampered update")
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let update = try makeUpdate(fileURL: fileURL, sha256: String(repeating: "0", count: 64))
    let service = StaticUpdateService(
        fetchResult: .success(try makeManifest()),
        downloadResult: .success(fileURL)
    )
    let workspace = RecordingWorkspace()
    let controller = SoftwareUpdateController(
        service: service,
        workspace: workspace,
        userDefaults: defaults,
        prepareForOpeningUpdate: {}
    )
    controller.state = .available(
        update,
        currentVersion: AppVersionInfo.current.version,
        wasPreviouslySkipped: false
    )

    let task = try #require(controller.downloadAvailableUpdate())
    await task.value

    guard case .verificationFailed(let failedUpdate, _) = controller.state else {
        Issue.record("Expected checksum verification to fail")
        return
    }
    #expect(failedUpdate == update)
    #expect(workspace.openedURLs.isEmpty)
    #expect(controller.hasUnacknowledgedUpdateIssue)
}

@MainActor
@Test func automaticCheckSuppressesBannerForPersistedSkippedVersion() async throws {
    let defaultsFixture = makeUserDefaults()
    let defaults = defaultsFixture.defaults
    defer { defaultsFixture.clear() }
    defaults.set("99.0.0", forKey: "EasyTierUpdaterSkippedVersion")

    let controller = SoftwareUpdateController(
        service: StaticUpdateService(fetchResult: .success(try makeManifest())),
        workspace: RecordingWorkspace(),
        userDefaults: defaults,
        prepareForOpeningUpdate: {}
    )

    let task = try #require(controller.scheduleAutomaticCheckIfNeeded())
    await task.value

    guard case .available(_, _, let wasPreviouslySkipped) = controller.state else {
        Issue.record("Automatic checks should retain a truthful skipped state")
        return
    }
    #expect(wasPreviouslySkipped)
    #expect(!controller.hasUnacknowledgedUpdate)
}

@MainActor
@Test func automaticSchedulerDoesNotReplaceManualCheck() async throws {
    let defaultsFixture = makeUserDefaults()
    let defaults = defaultsFixture.defaults
    defer { defaultsFixture.clear() }

    let service = DelayedFetchService()
    let controller = SoftwareUpdateController(
        service: service,
        workspace: RecordingWorkspace(),
        userDefaults: defaults,
        prepareForOpeningUpdate: {}
    )
    controller.setSoftwareUpdateWindowVisible(true)

    let manualTask = controller.checkForUpdates(origin: .manual)
    try await service.waitUntilFetchStarts()
    #expect(controller.scheduleAutomaticCheckIfNeeded() == nil)

    await service.finish(with: try makeManifest())
    await manualTask.value
    guard case .available(let update, _, _) = controller.state else {
        Issue.record("The manual check should remain active")
        return
    }
    #expect(update.version == "99.0.0")
}

@MainActor
@Test func cancelledURLRequestRestoresPreviousState() async {
    let defaultsFixture = makeUserDefaults()
    let defaults = defaultsFixture.defaults
    defer { defaultsFixture.clear() }

    let controller = SoftwareUpdateController(
        service: CancelledFetchService(),
        workspace: RecordingWorkspace(),
        userDefaults: defaults,
        prepareForOpeningUpdate: {}
    )
    controller.state = .noUpdate(currentVersion: "0.1.0")

    await controller.checkForUpdates(origin: .manual).value
    #expect(controller.state == .noUpdate(currentVersion: "0.1.0"))
}

@MainActor
@Test func automaticCheckRaisesBannerForNewVersion() async throws {
    let defaultsFixture = makeUserDefaults()
    let defaults = defaultsFixture.defaults
    defer { defaultsFixture.clear() }

    let controller = SoftwareUpdateController(
        service: StaticUpdateService(fetchResult: .success(try makeManifest())),
        workspace: RecordingWorkspace(),
        userDefaults: defaults,
        prepareForOpeningUpdate: {}
    )

    let task = try #require(controller.scheduleAutomaticCheckIfNeeded())
    await task.value

    guard case .available(_, _, let wasPreviouslySkipped) = controller.state else {
        Issue.record("Expected an available update")
        return
    }
    #expect(!wasPreviouslySkipped)
    #expect(controller.hasUnacknowledgedUpdate)
}

@MainActor
@Test func cancelDownloadIgnoresLateProgressAndCompletion() async throws {
    let defaultsFixture = makeUserDefaults()
    let defaults = defaultsFixture.defaults
    defer { defaultsFixture.clear() }

    let fileURL = try makeFixtureFile(contents: "late update")
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let digest = try EasyTierSHA256.hexDigest(for: fileURL)
    let update = try makeUpdate(fileURL: fileURL, sha256: digest)
    let service = DelayedDownloadService()
    let workspace = RecordingWorkspace()
    var preparationCount = 0
    let controller = SoftwareUpdateController(
        service: service,
        workspace: workspace,
        userDefaults: defaults,
        prepareForOpeningUpdate: { preparationCount += 1 }
    )
    controller.state = .available(
        update,
        currentVersion: AppVersionInfo.current.version,
        wasPreviouslySkipped: false
    )

    let task = try #require(controller.downloadAvailableUpdate())
    try await service.waitUntilDownloadStarts()
    controller.cancelDownload()

    await service.emitProgress(0.9)
    await service.finish(with: fileURL)
    await task.value

    #expect(controller.state == .available(
        update,
        currentVersion: AppVersionInfo.current.version,
        wasPreviouslySkipped: false
    ))
    #expect(preparationCount == 0)
    #expect(workspace.openedURLs.isEmpty)
}

@MainActor
@Test func workspaceOpenFailureKeepsRetryContext() async throws {
    let defaultsFixture = makeUserDefaults()
    let defaults = defaultsFixture.defaults
    defer { defaultsFixture.clear() }

    let fileURL = try makeFixtureFile(contents: "verified but unopened")
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let digest = try EasyTierSHA256.hexDigest(for: fileURL)
    let update = try makeUpdate(fileURL: fileURL, sha256: digest)
    let workspace = RecordingWorkspace()
    workspace.shouldOpen = false
    let controller = SoftwareUpdateController(
        service: StaticUpdateService(
            fetchResult: .success(try makeManifest()),
            downloadResult: .success(fileURL)
        ),
        workspace: workspace,
        userDefaults: defaults,
        prepareForOpeningUpdate: {}
    )
    controller.state = .available(update, currentVersion: "0.1.0", wasPreviouslySkipped: false)

    let task = try #require(controller.downloadAvailableUpdate())
    await task.value

    guard case .downloadFailed(let failedUpdate, _) = controller.state else {
        Issue.record("Expected the verified update to retain retry context")
        return
    }
    #expect(failedUpdate == update)
    #expect(workspace.openedURLs == [fileURL])
    #expect(controller.hasUnacknowledgedUpdateIssue)
}

private struct StaticUpdateService: SoftwareUpdateServicing {
    var fetchResult: Result<EasyTierUpdateManifest, TestUpdateError>
    var downloadResult: Result<URL, TestUpdateError> = .failure(.downloadFailed)

    func fetchManifest() async throws -> EasyTierUpdateManifest {
        try fetchResult.get()
    }

    func download(
        update _: EasyTierAvailableUpdate,
        progress: @escaping @MainActor @Sendable (Double?) -> Void
    ) async throws -> URL {
        await progress(1)
        return try downloadResult.get()
    }
}

private struct CancelledFetchService: SoftwareUpdateServicing {
    func fetchManifest() async throws -> EasyTierUpdateManifest {
        throw URLError(.cancelled)
    }

    func download(
        update _: EasyTierAvailableUpdate,
        progress _: @escaping @MainActor @Sendable (Double?) -> Void
    ) async throws -> URL {
        throw URLError(.cancelled)
    }
}

private actor DelayedFetchService: SoftwareUpdateServicing {
    private var continuation: CheckedContinuation<EasyTierUpdateManifest, any Error>?
    private var didStart = false

    func fetchManifest() async throws -> EasyTierUpdateManifest {
        didStart = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func download(
        update _: EasyTierAvailableUpdate,
        progress _: @escaping @MainActor @Sendable (Double?) -> Void
    ) async throws -> URL {
        throw TestUpdateError.downloadFailed
    }

    func waitUntilFetchStarts() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !didStart, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard didStart else { throw TestUpdateError.timedOut }
    }

    func finish(with manifest: EasyTierUpdateManifest) {
        continuation?.resume(returning: manifest)
        continuation = nil
    }
}

private actor DelayedDownloadService: SoftwareUpdateServicing {
    private var continuation: CheckedContinuation<URL, any Error>?
    private var progressHandler: (@MainActor @Sendable (Double?) -> Void)?
    private var didStart = false

    func fetchManifest() async throws -> EasyTierUpdateManifest {
        throw TestUpdateError.fetchFailed
    }

    func download(
        update _: EasyTierAvailableUpdate,
        progress: @escaping @MainActor @Sendable (Double?) -> Void
    ) async throws -> URL {
        didStart = true
        progressHandler = progress
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilDownloadStarts() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !didStart, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard didStart else { throw TestUpdateError.timedOut }
    }

    func emitProgress(_ value: Double?) async {
        await progressHandler?(value)
    }

    func finish(with fileURL: URL) {
        continuation?.resume(returning: fileURL)
        continuation = nil
    }
}

private actor SequencedFetchService: SoftwareUpdateServicing {
    private var continuations: [CheckedContinuation<EasyTierUpdateManifest, any Error>?] = []

    func fetchManifest() async throws -> EasyTierUpdateManifest {
        let index = continuations.count
        continuations.append(nil)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func download(
        update _: EasyTierAvailableUpdate,
        progress _: @escaping @MainActor @Sendable (Double?) -> Void
    ) async throws -> URL {
        throw TestUpdateError.downloadFailed
    }

    func waitUntilFetchCount(_ expectedCount: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !hasFetchCount(expectedCount), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard hasFetchCount(expectedCount) else { throw TestUpdateError.timedOut }
    }

    func finishFetch(at index: Int, with manifest: EasyTierUpdateManifest) {
        guard continuations.indices.contains(index) else { return }
        continuations[index]?.resume(returning: manifest)
        continuations[index] = nil
    }

    private func hasFetchCount(_ expectedCount: Int) -> Bool {
        continuations.count >= expectedCount && continuations.prefix(expectedCount).allSatisfy { $0 != nil }
    }
}

@MainActor
private final class RecordingWorkspace: SoftwareUpdateWorkspaceClient {
    var shouldOpen = true
    private(set) var openedURLs: [URL] = []
    private(set) var revealedURLGroups: [[URL]] = []

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return shouldOpen
    }

    func reveal(_ urls: [URL]) {
        revealedURLGroups.append(urls)
    }
}

private enum TestUpdateError: Error, LocalizedError, Sendable {
    case fetchFailed
    case downloadFailed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .fetchFailed: "Test update check failed."
        case .downloadFailed: "Test update download failed."
        case .timedOut: "Timed out waiting for the test service."
        }
    }
}

private func makeManifest(version: String = "99.0.0") throws -> EasyTierUpdateManifest {
    let releaseNotesURL = try #require(URL(string: "https://example.com/releases/\(version)"))
    let assetURL = try #require(URL(string: "https://example.com/EasyTier.dmg"))
    let asset = EasyTierUpdateAsset(
        url: assetURL,
        sha256: String(repeating: "a", count: 64),
        size: 123_456
    )
    return EasyTierUpdateManifest(
        schemaVersion: 1,
        channel: "stable",
        version: version,
        build: "99999999999999",
        tag: "v\(version)",
        minimumSystemVersion: "14.0",
        releaseNotesURL: releaseNotesURL,
        assets: ["arm64": asset, "x86_64": asset]
    )
}

private func makeNoUpdateManifest() throws -> EasyTierUpdateManifest {
    var manifest = try makeManifest(version: AppVersionInfo.current.version)
    manifest.build = AppVersionInfo.current.rawBuild
    return manifest
}

private func makeUpdate(fileURL: URL, sha256: String) throws -> EasyTierAvailableUpdate {
    EasyTierAvailableUpdate(
        version: "99.0.0",
        build: "99999999999999",
        tag: "v99.0.0",
        releaseNotesURL: try #require(URL(string: "https://example.com/releases/99.0.0")),
        architecture: "arm64",
        asset: EasyTierUpdateAsset(url: fileURL, sha256: sha256, size: 15)
    )
}

private func makeFixtureFile(contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("EasyTier.dmg")
    try Data(contents.utf8).write(to: fileURL)
    return fileURL
}

private struct UserDefaultsFixture {
    var suiteName: String
    var defaults: UserDefaults

    func clear() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private func makeUserDefaults() -> UserDefaultsFixture {
    let suiteName = "SoftwareUpdateControllerTests.\(UUID().uuidString)"
    return UserDefaultsFixture(
        suiteName: suiteName,
        defaults: UserDefaults(suiteName: suiteName) ?? .standard
    )
}
