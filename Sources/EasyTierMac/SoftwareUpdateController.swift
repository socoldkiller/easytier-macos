import AppKit
import EasyTierShared
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class SoftwareUpdateController {
    var state: SoftwareUpdateState = .idle

    var isPresentingUpdateSheet = false

    var autoCheckOnLaunch: Bool {
        get { userDefaults.object(forKey: Self.autoCheckKey) as? Bool ?? true }
        set { userDefaults.set(newValue, forKey: Self.autoCheckKey) }
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

    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var didAutoCheckThisLaunch = false

    private let service: GitHubReleaseUpdateService
    private let userDefaults: UserDefaults

    init(
        service: GitHubReleaseUpdateService = .default,
        userDefaults: UserDefaults = .standard
    ) {
        self.service = service
        self.userDefaults = userDefaults
    }

    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    func checkForUpdates() {
        activeTask?.cancel()
        activeTask = Task { await runUpdateCheck() }
    }

    func presentUpdateSheet() {
        isPresentingUpdateSheet = true
    }

    func dismissUpdateSheet() {
        isPresentingUpdateSheet = false
    }

    func checkForUpdatesAndPresent() {
        presentUpdateSheet()
        checkForUpdates()
    }

    func scheduleAutomaticCheckIfNeeded() {
        guard autoCheckOnLaunch, !didAutoCheckThisLaunch else { return }
        didAutoCheckThisLaunch = true

        guard shouldAutoCheckNow() else { return }

        activeTask?.cancel()
        activeTask = Task { await runUpdateCheck(autoPresentSheetOnUpdate: true) }
    }

    func downloadAvailableUpdate() {
        guard let update = state.downloadableUpdate else { return }
        activeTask?.cancel()
        activeTask = Task { await download(update) }
    }

    func cancelDownload() {
        guard isDownloading else { return }
        activeTask?.cancel()
        if let update = state.visibleUpdate {
            state = .available(update, currentVersion: AppVersionInfo.current.version)
        }
    }

    func skipAvailableUpdate() {
        guard let update = state.availableUpdate else { return }
        userDefaults.set(update.version, forKey: Self.skippedVersionKey)
        hasUnacknowledgedUpdate = false
        state = .noUpdate(currentVersion: AppVersionInfo.current.version)
    }

    func remindLater() {
        guard state.availableUpdate != nil else { return }
        hasUnacknowledgedUpdate = false
        dismissUpdateSheet()
    }

    func openReleaseNotes() {
        guard let update = state.visibleUpdate else { return }
        NSWorkspace.shared.open(update.releaseNotesURL)
    }

    func revealDownloadedInFinder() {
        guard case .readyToInstall(_, let fileURL) = state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func quitEasyTier() {
        EasyTierApplicationDelegate.quitEasyTier()
    }

    private func runUpdateCheck(autoPresentSheetOnUpdate: Bool = false) async {
        state = .checking
        do {
            let manifest = try await service.fetchManifest()
            let appInfo = AppVersionInfo.current
            let update = try EasyTierUpdateSelector.availableUpdate(
                in: manifest,
                currentVersion: appInfo.version,
                currentBuild: appInfo.rawBuild,
                currentSystemVersion: Self.currentSystemVersion,
                architecture: Self.currentArchitecture
            )
            if let update {
                if wasSkipped(update) {
                    state = .noUpdate(currentVersion: appInfo.version)
                } else {
                    state = .available(update, currentVersion: appInfo.version)
                    hasUnacknowledgedUpdate = true
                    if autoPresentSheetOnUpdate {
                        presentUpdateSheet()
                    }
                }
            } else {
                state = .noUpdate(currentVersion: appInfo.version)
            }
            recordSuccessfulCheckDate()
        } catch is CancellationError {
            return
        } catch {
            state = .failed(message: Self.message(for: error))
        }
    }

    private func download(_ update: EasyTierAvailableUpdate) async {
        state = .downloading(update, progress: 0)
        do {
            let fileURL = try await service.download(update: update) { [weak self] progress in
                guard let self, case .downloading(let downloadingUpdate, _) = self.state,
                      downloadingUpdate == update else { return }
                self.state = .downloading(update, progress: progress)
            }
            guard try EasyTierSHA256.file(fileURL, matches: update.asset.sha256) else {
                state = .verificationFailed(update, message: "The downloaded DMG did not match the published checksum.")
                return
            }
            await unregisterHelperBeforeOpeningUpdate()
            guard NSWorkspace.shared.open(fileURL) else {
                state = .downloadFailed(update, message: "The DMG was downloaded, but macOS could not open it.")
                return
            }
            state = .readyToInstall(update, fileURL: fileURL)
        } catch is CancellationError {
            state = .available(update, currentVersion: AppVersionInfo.current.version)
        } catch {
            state = .downloadFailed(update, message: Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription
        {
            return description
        }
        return error.localizedDescription
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

    private func unregisterHelperBeforeOpeningUpdate() async {
        let service = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName)
        try? await service.unregister()
    }
}

enum SoftwareUpdateState: Equatable {
    case idle
    case checking
    case noUpdate(currentVersion: String)
    case available(EasyTierAvailableUpdate, currentVersion: String)
    case downloading(EasyTierAvailableUpdate, progress: Double?)
    case failed(message: String)
    case downloadFailed(EasyTierAvailableUpdate, message: String)
    case verificationFailed(EasyTierAvailableUpdate, message: String)
    case readyToInstall(EasyTierAvailableUpdate, fileURL: URL)

    var availableUpdate: EasyTierAvailableUpdate? {
        if case .available(let update, _) = self { return update }
        return nil
    }

    var downloadableUpdate: EasyTierAvailableUpdate? {
        switch self {
        case .available(let update, _), .downloadFailed(let update, _), .verificationFailed(let update, _):
            return update
        default:
            return nil
        }
    }

    var visibleUpdate: EasyTierAvailableUpdate? {
        switch self {
        case .available(let update, _), .downloading(let update, _), .downloadFailed(let update, _),
             .verificationFailed(let update, _), .readyToInstall(let update, _):
            return update
        default:
            return nil
        }
    }
}

struct GitHubReleaseUpdateService {
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
