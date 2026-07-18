import Foundation
import Observation

@MainActor
@Observable
final class SoftwareUpdateController: SoftwareUpdateClientDelegate {
    typealias ClientFactory = @MainActor (any SoftwareUpdateClientDelegate) -> any SoftwareUpdateClient

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
    private let captureGatewayDesiredEnabled: @MainActor () -> Bool
    private let prepareForInstallation: @MainActor () async -> Void
    private let restoreRunningConfigIDs: @MainActor ([String]) async -> Void
    private let restoreGatewayDesiredEnabled: @MainActor (Bool) async -> Void
    private let recordNotice: @MainActor (String) -> Void

    init(
        userDefaults: UserDefaults,
        currentBuild: String = AppVersionInfo.current.rawBuild,
        preparationTimeout: Duration = .seconds(30),
        clientFactory: ClientFactory,
        captureRunningConfigIDs: @escaping @MainActor () -> [String] = { [] },
        captureGatewayDesiredEnabled: @escaping @MainActor () -> Bool = { false },
        prepareForInstallation: @escaping @MainActor () async -> Void = {},
        restoreRunningConfigIDs: @escaping @MainActor ([String]) async -> Void = { _ in },
        restoreGatewayDesiredEnabled: @escaping @MainActor (Bool) async -> Void = { _ in },
        recordNotice: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        let storedTrack = userDefaults.string(forKey: Self.updateTrackKey)
            .flatMap(SoftwareUpdateTrack.init(rawValue:)) ?? .stable
        self.userDefaults = userDefaults
        self.currentBuild = currentBuild
        updateTrack = storedTrack
        self.preparationTimeout = preparationTimeout
        self.captureRunningConfigIDs = captureRunningConfigIDs
        self.captureGatewayDesiredEnabled = captureGatewayDesiredEnabled
        self.prepareForInstallation = prepareForInstallation
        self.restoreRunningConfigIDs = restoreRunningConfigIDs
        self.restoreGatewayDesiredEnabled = restoreGatewayDesiredEnabled
        self.recordNotice = recordNotice
        migrateLegacyPreferencesIfNeeded()
        userDefaults.set(updateTrack.rawValue, forKey: Self.updateTrackKey)
        client = clientFactory(self)
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

    var allowedChannels: Set<String> {
        updateTrack.allowedChannels
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
        await restoreGatewayDesiredEnabled(state.gatewayDesiredEnabled)
    }

    func shouldPostponeInstallation(
        targetBuild: String,
        installHandler: @escaping () -> Void
    ) -> Bool {
        _ = beginInstallationPreparation(targetBuild: targetBuild, installHandler: installHandler)
        return true
    }

    func softwareUpdateDidAbort(with error: Error) {
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
            gatewayDesiredEnabled: captureGatewayDesiredEnabled(),
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
        await restoreGatewayDesiredEnabled(state.gatewayDesiredEnabled)
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
