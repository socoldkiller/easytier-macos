import Foundation
import Observation
import Sparkle

enum SoftwareUpdateTrack: String, CaseIterable, Identifiable, Sendable {
    case stable
    case nightly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stable: "Latest Stable"
        case .nightly: "Nightly"
        }
    }

    var buildDisplayName: String {
        switch self {
        case .stable: "Stable"
        case .nightly: "Nightly"
        }
    }

    var allowedSparkleChannels: Set<String> {
        switch self {
        case .stable: []
        case .nightly: ["nightly"]
        }
    }
}

@MainActor
protocol SoftwareUpdateClient: AnyObject {
    var canCheckForUpdates: Bool { get }
    var sessionInProgress: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    var stateDidChange: (@MainActor () -> Void)? { get set }

    func start()
    func checkForUpdates()
    func resetUpdateCycleAfterShortDelay()
}

@MainActor
final class SparkleSoftwareUpdateClient: SoftwareUpdateClient {
    var stateDidChange: (@MainActor () -> Void)?

    private let controller: SPUStandardUpdaterController
    private var observations: [NSKeyValueObservation] = []

    init(delegate: any SPUUpdaterDelegate) {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )

        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.stateDidChange?() }
            },
            updater.observe(\.sessionInProgress, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.stateDidChange?() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.stateDidChange?() }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.stateDidChange?() }
            },
        ]
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var sessionInProgress: Bool { controller.updater.sessionInProgress }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        else {
            stateDidChange?()
            return
        }
        controller.startUpdater()
        stateDidChange?()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func resetUpdateCycleAfterShortDelay() {
        controller.updater.resetUpdateCycleAfterShortDelay()
    }
}

struct SoftwareUpdateRuntimeRestoreState: Codable, Equatable {
    var sourceBuild: String
    var targetBuild: String
    var configIDs: [String]
    var createdAt: Date
}

@MainActor
@Observable
final class SoftwareUpdateController: NSObject, SPUUpdaterDelegate {
    typealias ClientFactory = @MainActor (any SPUUpdaterDelegate) -> any SoftwareUpdateClient

    private(set) var canCheckForUpdates = false
    private(set) var sessionInProgress = false
    private(set) var lastUpdateCheckDate: Date?
    private(set) var isStarted = false

    var updateTrack: SoftwareUpdateTrack {
        didSet {
            guard updateTrack != oldValue else { return }
            userDefaults.set(updateTrack.rawValue, forKey: Self.updateTrackKey)
            client?.resetUpdateCycleAfterShortDelay()
        }
    }

    var automaticallyChecksForUpdates = true {
        didSet {
            guard !isSynchronizingState else { return }
            client?.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            synchronizeState()
        }
    }

    @ObservationIgnored private var client: (any SoftwareUpdateClient)?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var preparedRestoreState: SoftwareUpdateRuntimeRestoreState?
    @ObservationIgnored private var didPrepareForInstallation = false
    @ObservationIgnored private var isSynchronizingState = false

    private let userDefaults: UserDefaults
    private let currentBuild: String
    private let preparationTimeout: Duration
    private let captureRunningConfigIDs: @MainActor () -> [String]
    private let prepareForInstallation: @MainActor () async -> Void
    private let restoreRunningConfigIDs: @MainActor ([String]) async -> Void
    private let recordNotice: @MainActor (String) -> Void

    init(
        userDefaults: UserDefaults = .standard,
        currentBuild: String = AppVersionInfo.current.rawBuild,
        preparationTimeout: Duration = .seconds(30),
        clientFactory: ClientFactory? = nil,
        captureRunningConfigIDs: @escaping @MainActor () -> [String] = { [] },
        prepareForInstallation: @escaping @MainActor () async -> Void = {},
        restoreRunningConfigIDs: @escaping @MainActor ([String]) async -> Void = { _ in },
        recordNotice: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        let storedTrack = userDefaults.string(forKey: Self.updateTrackKey)
            .flatMap(SoftwareUpdateTrack.init(rawValue:)) ?? .stable
        self.userDefaults = userDefaults
        self.currentBuild = currentBuild
        updateTrack = storedTrack
        self.preparationTimeout = preparationTimeout
        self.captureRunningConfigIDs = captureRunningConfigIDs
        self.prepareForInstallation = prepareForInstallation
        self.restoreRunningConfigIDs = restoreRunningConfigIDs
        self.recordNotice = recordNotice
        super.init()

        migrateLegacyPreferencesIfNeeded()
        userDefaults.set(updateTrack.rawValue, forKey: Self.updateTrackKey)
        if let clientFactory {
            client = clientFactory(self)
        } else {
            client = SparkleSoftwareUpdateClient(delegate: self)
        }
        client?.stateDidChange = { [weak self] in self?.synchronizeState() }
        synchronizeState()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        client?.start()
        synchronizeState()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        client?.checkForUpdates()
    }

    var allowedSparkleChannels: Set<String> {
        updateTrack.allowedSparkleChannels
    }

    func allowedChannels(for _: SPUUpdater) -> Set<String> {
        allowedSparkleChannels
    }

    func restorePendingRuntimeIfNeeded() async {
        guard let state = pendingRestoreState() else { return }
        guard state.sourceBuild == currentBuild || state.targetBuild == currentBuild else {
            clearPendingRestoreState()
            recordNotice("Discarded software update recovery state for an unrelated build.")
            return
        }

        clearPendingRestoreState()
        preparedRestoreState = nil
        didPrepareForInstallation = false

        if !state.configIDs.isEmpty {
            recordNotice("Restoring \(state.configIDs.count) network configuration(s) after software update.")
        }
        await restoreRunningConfigIDs(state.configIDs)
    }

    func updater(
        _: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        _ = beginInstallationPreparation(targetBuild: item.versionString, installHandler: installHandler)
        return true
    }

    func updater(_: SPUUpdater, didAbortWithError error: Error) {
        _ = handleInstallationAbort(error)
    }

    @discardableResult
    func handleInstallationAbort(_ error: Error) -> Task<Void, Never>? {
        guard preparationTask != nil || didPrepareForInstallation else { return nil }
        let pendingPreparation = preparationTask
        pendingPreparation?.cancel()
        preparationTask = nil
        recordNotice("Software update installation stopped: \(error.localizedDescription)")

        return Task { [weak self] in
            await pendingPreparation?.value
            await self?.restorePreparedRuntimeAfterAbort()
        }
    }

    @discardableResult
    func beginInstallationPreparation(
        targetBuild: String,
        installHandler: @escaping () -> Void
    ) -> Task<Void, Never>? {
        guard preparationTask == nil else {
            recordNotice("Ignored a duplicate software update installation request.")
            return nil
        }

        let state = SoftwareUpdateRuntimeRestoreState(
            sourceBuild: currentBuild,
            targetBuild: targetBuild,
            configIDs: captureRunningConfigIDs().sorted(),
            createdAt: Date()
        )
        preparedRestoreState = state
        persistPendingRestoreState(state)

        let task = Task { [weak self] in
            guard let self else {
                installHandler()
                return
            }

            let completed = await SoftwareUpdatePreparationRace.run(
                timeout: self.preparationTimeout,
                operation: self.prepareForInstallation
            )
            if !completed {
                self.recordNotice("Software update preparation exceeded its time limit; continuing after best-effort cleanup.")
            }

            guard !Task.isCancelled else { return }
            self.didPrepareForInstallation = true
            self.preparationTask = nil
            installHandler()
        }
        preparationTask = task
        return task
    }

    private func restorePreparedRuntimeAfterAbort() async {
        let state = preparedRestoreState ?? pendingRestoreState()
        clearPendingRestoreState()
        preparedRestoreState = nil
        didPrepareForInstallation = false
        guard let state else { return }
        await restoreRunningConfigIDs(state.configIDs)
    }

    private func synchronizeState() {
        guard let client else { return }
        isSynchronizingState = true
        canCheckForUpdates = client.canCheckForUpdates
        sessionInProgress = client.sessionInProgress
        automaticallyChecksForUpdates = client.automaticallyChecksForUpdates
        lastUpdateCheckDate = client.lastUpdateCheckDate
        isSynchronizingState = false
    }

    private func migrateLegacyPreferencesIfNeeded() {
        if userDefaults.object(forKey: Self.sparkleAutomaticChecksKey) == nil,
           let legacyValue = userDefaults.object(forKey: Self.legacyAutomaticChecksKey) as? Bool
        {
            userDefaults.set(legacyValue, forKey: Self.sparkleAutomaticChecksKey)
        }

        if userDefaults.object(forKey: Self.sparkleLastCheckDateKey) == nil,
           let legacyDate = userDefaults.object(forKey: Self.legacyLastCheckDateKey) as? Date
        {
            userDefaults.set(legacyDate, forKey: Self.sparkleLastCheckDateKey)
        }

        userDefaults.removeObject(forKey: Self.legacyAutomaticChecksKey)
        userDefaults.removeObject(forKey: Self.legacyLastCheckDateKey)
        userDefaults.removeObject(forKey: Self.legacySkippedVersionKey)
    }

    private func persistPendingRestoreState(_ state: SoftwareUpdateRuntimeRestoreState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        userDefaults.set(data, forKey: Self.pendingRestoreStateKey)
    }

    private func pendingRestoreState() -> SoftwareUpdateRuntimeRestoreState? {
        guard let data = userDefaults.data(forKey: Self.pendingRestoreStateKey) else { return nil }
        return try? JSONDecoder().decode(SoftwareUpdateRuntimeRestoreState.self, from: data)
    }

    private func clearPendingRestoreState() {
        userDefaults.removeObject(forKey: Self.pendingRestoreStateKey)
    }

    private static let legacyAutomaticChecksKey = "EasyTierAutoCheckUpdates"
    private static let legacyLastCheckDateKey = "EasyTierLastUpdateCheckDate"
    private static let legacySkippedVersionKey = "EasyTierUpdaterSkippedVersion"
    private static let sparkleAutomaticChecksKey = "SUEnableAutomaticChecks"
    private static let sparkleLastCheckDateKey = "SULastCheckTime"
    private static let updateTrackKey = "EasyTierSoftwareUpdateTrack"
    private static let pendingRestoreStateKey = "EasyTierPendingSoftwareUpdateRuntimeRestore"
}

@MainActor
private final class SoftwareUpdatePreparationRace {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    static func run(
        timeout: Duration,
        operation: @escaping @MainActor () async -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let race = SoftwareUpdatePreparationRace(continuation: continuation)
            race.start(timeout: timeout, operation: operation)
        }
    }

    private init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    private func start(
        timeout: Duration,
        operation: @escaping @MainActor () async -> Void
    ) {
        operationTask = Task {
            await operation()
            finish(completed: true)
        }
        timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            operationTask?.cancel()
            finish(completed: false)
        }
    }

    private func finish(completed: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        if completed {
            timeoutTask?.cancel()
        }
        operationTask = nil
        timeoutTask = nil
        continuation.resume(returning: completed)
    }
}
