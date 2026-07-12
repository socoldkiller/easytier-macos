import AppKit
import EasyTierShared
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class SoftwareUpdateController {
    var state: SoftwareUpdateState = .idle

    var autoCheckOnLaunch: Bool {
        didSet {
            userDefaults.set(autoCheckOnLaunch, forKey: Self.autoCheckKey)
        }
    }

    var lastCheckDate: Date? {
        userDefaults.object(forKey: Self.lastCheckDateKey) as? Date
    }

    var lastCheckFormatted: String? {
        guard let date = lastCheckDate else { return nil }
        let calendar = Calendar.current
        let timeText = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) {
            return "Today, \(timeText)"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday, \(timeText)"
        } else {
            let dateText = date.formatted(date: .abbreviated, time: .omitted)
            return "\(dateText), \(timeText)"
        }
    }

    private(set) var hasUnacknowledgedUpdate = false
    private(set) var hasUnacknowledgedUpdateIssue = false
    private(set) var isSoftwareUpdateWindowVisible = false

    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var checkOperationID: UUID?
    @ObservationIgnored private var stateBeforeCheck: SoftwareUpdateState?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var downloadOperationID: UUID?
    @ObservationIgnored private var didAutoCheckThisLaunch = false

    private let service: any SoftwareUpdateServicing
    private let workspace: any SoftwareUpdateWorkspaceClient
    private let userDefaults: UserDefaults
    private let prepareForOpeningUpdate: @MainActor @Sendable () async -> Void

    init(
        service: any SoftwareUpdateServicing = GitHubReleaseUpdateService.default,
        workspace: any SoftwareUpdateWorkspaceClient = AppKitSoftwareUpdateWorkspaceClient(),
        userDefaults: UserDefaults = .standard,
        prepareForOpeningUpdate: @escaping @MainActor @Sendable () async -> Void = SoftwareUpdateController.livePrepareForOpeningUpdate
    ) {
        self.service = service
        self.workspace = workspace
        self.userDefaults = userDefaults
        self.prepareForOpeningUpdate = prepareForOpeningUpdate
        autoCheckOnLaunch = userDefaults.object(forKey: Self.autoCheckKey) as? Bool ?? true
    }

    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    @discardableResult
    func checkForUpdates(origin: SoftwareUpdateCheckOrigin = .manual) -> Task<Void, Never> {
        guard !isDownloading else { return Task {} }

        if origin == .manual {
            hasUnacknowledgedUpdate = false
            hasUnacknowledgedUpdateIssue = false
        }

        let previousState = state == .checking ? stateBeforeCheck ?? .idle : state
        checkOperationID = nil
        checkTask?.cancel()

        let operationID = UUID()
        stateBeforeCheck = previousState
        checkOperationID = operationID
        state = .checking

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runUpdateCheck(origin: origin, operationID: operationID)
        }
        checkTask = task
        return task
    }

    @discardableResult
    func scheduleAutomaticCheckIfNeeded() -> Task<Void, Never>? {
        guard autoCheckOnLaunch, !didAutoCheckThisLaunch, !isDownloading, !isChecking else { return nil }
        didAutoCheckThisLaunch = true

        guard shouldAutoCheckNow() else { return nil }
        return checkForUpdates(origin: .automatic)
    }

    func cancelCheck() {
        guard checkOperationID != nil else { return }
        let restoredState = stateBeforeCheck ?? .idle
        checkOperationID = nil
        checkTask?.cancel()
        checkTask = nil
        stateBeforeCheck = nil
        state = restoredState
    }

    @discardableResult
    func downloadAvailableUpdate() -> Task<Void, Never>? {
        guard let update = state.downloadableUpdate else { return nil }
        if userDefaults.string(forKey: Self.skippedVersionKey) == update.version {
            userDefaults.removeObject(forKey: Self.skippedVersionKey)
        }

        acknowledgeAvailableUpdate()
        acknowledgeUpdateIssue()
        downloadOperationID = nil
        downloadTask?.cancel()

        let operationID = UUID()
        downloadOperationID = operationID
        state = .downloading(update, progress: 0)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.download(update, operationID: operationID)
        }
        downloadTask = task
        return task
    }

    func cancelDownload() {
        guard case .downloading(let update, _) = state else { return }
        downloadOperationID = nil
        downloadTask?.cancel()
        downloadTask = nil
        hasUnacknowledgedUpdateIssue = false
        state = .available(update, currentVersion: AppVersionInfo.current.version, wasPreviouslySkipped: false)
    }

    func skipAvailableUpdate() {
        guard case .available(let update, let currentVersion, _) = state else { return }
        userDefaults.set(update.version, forKey: Self.skippedVersionKey)
        hasUnacknowledgedUpdate = false
        state = .available(update, currentVersion: currentVersion, wasPreviouslySkipped: true)
    }

    func remindLater() {
        guard state.availableUpdate != nil else { return }
        hasUnacknowledgedUpdate = false
    }

    func acknowledgeAvailableUpdate() {
        hasUnacknowledgedUpdate = false
    }

    func acknowledgeUpdateIssue() {
        hasUnacknowledgedUpdateIssue = false
    }

    func setSoftwareUpdateWindowVisible(_ isVisible: Bool) {
        isSoftwareUpdateWindowVisible = isVisible
        if isVisible {
            acknowledgeAvailableUpdate()
            acknowledgeUpdateIssue()
        }
    }

    func openReleaseNotes() {
        guard let update = state.visibleUpdate else { return }
        workspace.open(update.releaseNotesURL)
    }

    func openIssueTracker() {
        guard let url = URL(string: "https://github.com/socoldkiller/easytier-macos/issues") else { return }
        workspace.open(url)
    }

    func revealDownloadedInFinder() {
        guard case .downloadComplete(_, let fileURL) = state else { return }
        workspace.reveal([fileURL])
    }

    func quitEasyTier() {
        EasyTierApplicationDelegate.quitEasyTier()
    }

    private func runUpdateCheck(origin: SoftwareUpdateCheckOrigin, operationID: UUID) async {
        defer { finishCheck(operationID: operationID) }

        do {
            let manifest = try await service.fetchManifest()
            try Task.checkCancellation()
            guard checkOperationID == operationID else { return }

            let appInfo = AppVersionInfo.current
            let update = try EasyTierUpdateSelector.availableUpdate(
                in: manifest,
                currentVersion: appInfo.version,
                currentBuild: appInfo.rawBuild,
                currentSystemVersion: Self.currentSystemVersion,
                architecture: Self.currentArchitecture
            )
            if let update {
                let wasPreviouslySkipped = wasSkipped(update)
                state = .available(
                    update,
                    currentVersion: appInfo.version,
                    wasPreviouslySkipped: wasPreviouslySkipped
                )
                hasUnacknowledgedUpdate = !wasPreviouslySkipped && !isSoftwareUpdateWindowVisible
                hasUnacknowledgedUpdateIssue = false
            } else {
                state = .noUpdate(currentVersion: appInfo.version)
                hasUnacknowledgedUpdate = false
                hasUnacknowledgedUpdateIssue = false
            }
            recordSuccessfulCheckDate()
        } catch {
            guard checkOperationID == operationID else { return }
            if Self.isCancellation(error) {
                state = stateBeforeCheck ?? .idle
            } else if origin == .manual {
                state = .failed(message: Self.message(for: error))
                hasUnacknowledgedUpdateIssue = !isSoftwareUpdateWindowVisible
            } else {
                state = stateBeforeCheck ?? .idle
            }
        }
    }

    private func download(_ update: EasyTierAvailableUpdate, operationID: UUID) async {
        defer { finishDownload(operationID: operationID) }

        do {
            let fileURL = try await service.download(update: update) { [weak self] progress in
                guard let self, self.downloadOperationID == operationID,
                      case .downloading(let downloadingUpdate, _) = self.state,
                      downloadingUpdate == update else { return }
                self.state = .downloading(update, progress: progress)
            }
            try Task.checkCancellation()
            guard downloadOperationID == operationID else { return }

            guard try EasyTierSHA256.file(fileURL, matches: update.asset.sha256) else {
                state = .verificationFailed(update, message: "The downloaded DMG did not match the published checksum.")
                hasUnacknowledgedUpdateIssue = !isSoftwareUpdateWindowVisible
                return
            }

            await prepareForOpeningUpdate()
            try Task.checkCancellation()
            guard downloadOperationID == operationID else { return }

            guard workspace.open(fileURL) else {
                state = .downloadFailed(update, message: "The DMG was downloaded, but macOS could not open it.")
                hasUnacknowledgedUpdateIssue = !isSoftwareUpdateWindowVisible
                return
            }
            state = .downloadComplete(update, fileURL: fileURL)
            hasUnacknowledgedUpdateIssue = false
        } catch {
            guard downloadOperationID == operationID else { return }
            if Self.isCancellation(error) {
                state = .available(update, currentVersion: AppVersionInfo.current.version, wasPreviouslySkipped: false)
                hasUnacknowledgedUpdateIssue = false
            } else {
                state = .downloadFailed(update, message: Self.message(for: error))
                hasUnacknowledgedUpdateIssue = !isSoftwareUpdateWindowVisible
            }
        }
    }

    private func finishCheck(operationID: UUID) {
        guard checkOperationID == operationID else { return }
        checkOperationID = nil
        checkTask = nil
        stateBeforeCheck = nil
    }

    private func finishDownload(operationID: UUID) {
        guard downloadOperationID == operationID else { return }
        downloadOperationID = nil
        downloadTask = nil
    }

    private static func message(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription
        {
            return description
        }
        return error.localizedDescription
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
    }

    private static var currentSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static let skippedVersionKey = "EasyTierUpdaterSkippedVersion"
    private static let autoCheckKey = "EasyTierAutoCheckUpdates"
    private static let lastCheckDateKey = "EasyTierLastUpdateCheckDate"
    private static let autoCheckMinimumInterval: TimeInterval = 60 * 60 * 24

    private func wasSkipped(_ update: EasyTierAvailableUpdate) -> Bool {
        !EasyTierUpdateSkipPolicy.shouldPresent(
            update: update,
            skippedVersion: userDefaults.string(forKey: Self.skippedVersionKey)
        )
    }

    private func shouldAutoCheckNow() -> Bool {
        EasyTierUpdateSkipPolicy.shouldAutoCheck(
            lastCheckDate: userDefaults.object(forKey: Self.lastCheckDateKey) as? Date,
            now: Date(),
            minimumInterval: Self.autoCheckMinimumInterval
        )
    }

    private func recordSuccessfulCheckDate() {
        userDefaults.set(Date(), forKey: Self.lastCheckDateKey)
    }

    private static func livePrepareForOpeningUpdate() async {
        let service = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName)
        try? await service.unregister()
    }
}

enum SoftwareUpdateCheckOrigin {
    case manual
    case automatic
}

enum SoftwareUpdateState: Equatable {
    case idle
    case checking
    case noUpdate(currentVersion: String)
    case available(EasyTierAvailableUpdate, currentVersion: String, wasPreviouslySkipped: Bool)
    case downloading(EasyTierAvailableUpdate, progress: Double?)
    case failed(message: String)
    case downloadFailed(EasyTierAvailableUpdate, message: String)
    case verificationFailed(EasyTierAvailableUpdate, message: String)
    case downloadComplete(EasyTierAvailableUpdate, fileURL: URL)

    var availableUpdate: EasyTierAvailableUpdate? {
        if case .available(let update, _, _) = self { return update }
        return nil
    }

    var downloadableUpdate: EasyTierAvailableUpdate? {
        switch self {
        case .available(let update, _, _), .downloadFailed(let update, _), .verificationFailed(let update, _):
            return update
        default:
            return nil
        }
    }

    var visibleUpdate: EasyTierAvailableUpdate? {
        switch self {
        case .available(let update, _, _), .downloading(let update, _), .downloadFailed(let update, _),
             .verificationFailed(let update, _), .downloadComplete(let update, _):
            return update
        default:
            return nil
        }
    }

    var needsAttention: Bool {
        switch self {
        case .failed, .downloadFailed, .verificationFailed:
            true
        default:
            false
        }
    }
}

protocol SoftwareUpdateServicing: Sendable {
    func fetchManifest() async throws -> EasyTierUpdateManifest

    func download(
        update: EasyTierAvailableUpdate,
        progress: @escaping @MainActor @Sendable (Double?) -> Void
    ) async throws -> URL
}

@MainActor
protocol SoftwareUpdateWorkspaceClient: AnyObject {
    @discardableResult
    func open(_ url: URL) -> Bool

    func reveal(_ urls: [URL])
}

@MainActor
final class AppKitSoftwareUpdateWorkspaceClient: SoftwareUpdateWorkspaceClient {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

struct GitHubReleaseUpdateService: SoftwareUpdateServicing, Sendable {
    var manifestURL: URL

    static var `default`: GitHubReleaseUpdateService {
        GitHubReleaseUpdateService(manifestURL: defaultManifestURL)
    }

    func fetchManifest() async throws -> EasyTierUpdateManifest {
        let data: Data
        if manifestURL.isFileURL {
            data = try Data(contentsOf: manifestURL)
        } else {
            let request = EasyTierUpdateFeedRequest.request(for: manifestURL)
            let (remoteData, response) = try await URLSession.shared.data(for: request)
            try validate(response: response)
            data = remoteData
        }
        return try JSONDecoder().decode(EasyTierUpdateManifest.self, from: data)
    }

    func download(
        update: EasyTierAvailableUpdate,
        progress: @escaping @MainActor @Sendable (Double?) -> Void
    ) async throws -> URL {
        let destinationDirectory = try downloadsDirectory()
        let destinationURL = destinationDirectory.appendingPathComponent(fileName(for: update), isDirectory: false)
        let temporaryURL = destinationDirectory.appendingPathComponent(".\(destinationURL.lastPathComponent).download", isDirectory: false)

        try? FileManager.default.removeItem(at: temporaryURL)
        try? FileManager.default.removeItem(at: destinationURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        if update.asset.url.isFileURL {
            try FileManager.default.copyItem(at: update.asset.url, to: temporaryURL)
            await progress(1)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            return destinationURL
        }

        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)

        let (bytes, response) = try await URLSession.shared.bytes(from: update.asset.url)
        try validate(response: response)

        let expectedBytes = response.expectedContentLength > 0 ? response.expectedContentLength : update.asset.size
        var receivedBytes: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)

        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    receivedBytes += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    await progress(progressValue(receivedBytes: receivedBytes, expectedBytes: expectedBytes))
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                receivedBytes += Int64(buffer.count)
                await progress(progressValue(receivedBytes: receivedBytes, expectedBytes: expectedBytes))
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private func downloadsDirectory() throws -> URL {
        let baseURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let directory = baseURL.appendingPathComponent("EasyTier Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fileName(for update: EasyTierAvailableUpdate) -> String {
        let remoteName = update.asset.url.lastPathComponent
        guard !remoteName.isEmpty else { return "EasyTier-\(update.tag)-\(update.architecture).dmg" }
        return remoteName
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw SoftwareUpdateDownloadError.httpStatus(http.statusCode)
        }
    }

    private func progressValue(receivedBytes: Int64, expectedBytes: Int64) -> Double? {
        guard expectedBytes > 0 else { return nil }
        return min(max(Double(receivedBytes) / Double(expectedBytes), 0), 1)
    }

    private static var defaultManifestURL: URL {
        if let override = ProcessInfo.processInfo.environment["EASYTIER_UPDATE_MANIFEST_URL"], !override.isEmpty {
            if override.contains("://"), let url = URL(string: override) { return url }
            return URL(fileURLWithPath: override)
        }
        return URL(string: "https://socoldkiller.github.io/easytier-macos/update.json") ?? URL(fileURLWithPath: "/dev/null")
    }
}

enum SoftwareUpdateDownloadError: Error, LocalizedError {
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status):
            "The update server returned HTTP \(status)."
        }
    }
}
