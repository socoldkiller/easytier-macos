import Foundation
import Testing
@testable import EasyTierMac

@MainActor
@Test func legacyUpdatePreferencesMigrateBeforeSparkleStarts() {
    let fixture = makeUserDefaults()
    defer { fixture.clear() }

    let date = Date(timeIntervalSince1970: 1_700_000_000)
    fixture.defaults.set(false, forKey: "EasyTierAutoCheckUpdates")
    fixture.defaults.set(date, forKey: "EasyTierLastUpdateCheckDate")
    fixture.defaults.set("1.3.3", forKey: "EasyTierUpdaterSkippedVersion")

    let client = TestSoftwareUpdateClient()
    let controller = SoftwareUpdateController(
        userDefaults: fixture.defaults,
        clientFactory: { _ in client }
    )

    #expect(fixture.defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool == false)
    #expect(fixture.defaults.object(forKey: "SULastCheckTime") as? Date == date)
    #expect(fixture.defaults.object(forKey: "EasyTierAutoCheckUpdates") == nil)
    #expect(fixture.defaults.object(forKey: "EasyTierLastUpdateCheckDate") == nil)
    #expect(fixture.defaults.object(forKey: "EasyTierUpdaterSkippedVersion") == nil)

    controller.start()
    controller.start()
    #expect(client.startCount == 1)
}

@MainActor
@Test func existingSparklePreferenceWinsOverLegacyValue() {
    let fixture = makeUserDefaults()
    defer { fixture.clear() }

    fixture.defaults.set(true, forKey: "SUEnableAutomaticChecks")
    fixture.defaults.set(false, forKey: "EasyTierAutoCheckUpdates")

    _ = SoftwareUpdateController(
        userDefaults: fixture.defaults,
        clientFactory: { _ in TestSoftwareUpdateClient() }
    )

    #expect(fixture.defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool == true)
}

@MainActor
@Test func controllerTracksSparkleStateAndForwardsUserActions() {
    let fixture = makeUserDefaults()
    defer { fixture.clear() }

    let client = TestSoftwareUpdateClient()
    let controller = SoftwareUpdateController(
        userDefaults: fixture.defaults,
        clientFactory: { _ in client }
    )

    controller.checkForUpdates()
    #expect(client.checkCount == 0)

    client.canCheckForUpdates = true
    client.sessionInProgress = true
    let checkDate = Date(timeIntervalSince1970: 1_710_000_000)
    client.lastUpdateCheckDate = checkDate

    #expect(controller.canCheckForUpdates)
    #expect(controller.sessionInProgress)
    #expect(controller.lastUpdateCheckDate == checkDate)

    controller.checkForUpdates()
    #expect(client.checkCount == 1)

    controller.automaticallyChecksForUpdates = false
    #expect(!client.automaticallyChecksForUpdates)
}

@MainActor
@Test func pendingRuntimeStateRestoresOnceOnTargetBuild() async throws {
    let fixture = makeUserDefaults()
    defer { fixture.clear() }

    var preparationCount = 0
    var installHandlerCount = 0
    let sourceController = SoftwareUpdateController(
        userDefaults: fixture.defaults,
        currentBuild: "100",
        clientFactory: { _ in TestSoftwareUpdateClient() },
        captureRunningConfigIDs: { ["network-b", "network-a"] },
        prepareForInstallation: { preparationCount += 1 }
    )

    let task = try #require(sourceController.beginInstallationPreparation(targetBuild: "200") {
        installHandlerCount += 1
    })
    await task.value

    #expect(preparationCount == 1)
    #expect(installHandlerCount == 1)
    #expect(fixture.defaults.data(forKey: pendingRestoreKey) != nil)

    var restoredIDs: [String] = []
    let targetController = SoftwareUpdateController(
        userDefaults: fixture.defaults,
        currentBuild: "200",
        clientFactory: { _ in TestSoftwareUpdateClient() },
        restoreRunningConfigIDs: { restoredIDs = $0 }
    )
    await targetController.restorePendingRuntimeIfNeeded()
    await targetController.restorePendingRuntimeIfNeeded()

    #expect(restoredIDs == ["network-a", "network-b"])
    #expect(fixture.defaults.data(forKey: pendingRestoreKey) == nil)
}

@MainActor
@Test func abortedInstallationRestoresRuntimeInCurrentProcess() async throws {
    let fixture = makeUserDefaults()
    defer { fixture.clear() }

    var restoredIDs: [String] = []
    let controller = SoftwareUpdateController(
        userDefaults: fixture.defaults,
        currentBuild: "100",
        clientFactory: { _ in TestSoftwareUpdateClient() },
        captureRunningConfigIDs: { ["network-a"] },
        restoreRunningConfigIDs: { restoredIDs = $0 }
    )

    let preparation = try #require(controller.beginInstallationPreparation(targetBuild: "200") {})
    await preparation.value
    let restoration = try #require(controller.handleInstallationAbort(TestUpdateError.installationStopped))
    await restoration.value

    #expect(restoredIDs == ["network-a"])
    #expect(fixture.defaults.data(forKey: pendingRestoreKey) == nil)
}

@MainActor
@Test func abortedInstallationRestoresLifecycleWhenNoNetworksWereRunning() async throws {
    let fixture = makeUserDefaults()
    defer { fixture.clear() }

    var restoreCalls: [[String]] = []
    let controller = SoftwareUpdateController(
        userDefaults: fixture.defaults,
        currentBuild: "100",
        clientFactory: { _ in TestSoftwareUpdateClient() },
        restoreRunningConfigIDs: { restoreCalls.append($0) }
    )

    let preparation = try #require(controller.beginInstallationPreparation(targetBuild: "200") {})
    await preparation.value
    let restoration = try #require(controller.handleInstallationAbort(TestUpdateError.installationStopped))
    await restoration.value

    #expect(restoreCalls == [[]])
    #expect(fixture.defaults.data(forKey: pendingRestoreKey) == nil)
}

@MainActor
@Test func unrelatedBuildDiscardsPendingRuntimeState() async throws {
    let fixture = makeUserDefaults()
    defer { fixture.clear() }

    let sourceController = SoftwareUpdateController(
        userDefaults: fixture.defaults,
        currentBuild: "100",
        clientFactory: { _ in TestSoftwareUpdateClient() },
        captureRunningConfigIDs: { ["network-a"] }
    )
    let preparation = try #require(sourceController.beginInstallationPreparation(targetBuild: "200") {})
    await preparation.value

    var restoreCount = 0
    var notices: [String] = []
    let unrelatedController = SoftwareUpdateController(
        userDefaults: fixture.defaults,
        currentBuild: "999",
        clientFactory: { _ in TestSoftwareUpdateClient() },
        restoreRunningConfigIDs: { _ in restoreCount += 1 },
        recordNotice: { notices.append($0) }
    )
    await unrelatedController.restorePendingRuntimeIfNeeded()

    #expect(restoreCount == 0)
    #expect(notices == ["Discarded software update recovery state for an unrelated build."])
    #expect(fixture.defaults.data(forKey: pendingRestoreKey) == nil)
}

@MainActor
private final class TestSoftwareUpdateClient: SoftwareUpdateClient {
    var canCheckForUpdates = false { didSet { stateDidChange?() } }
    var sessionInProgress = false { didSet { stateDidChange?() } }
    var automaticallyChecksForUpdates = true { didSet { stateDidChange?() } }
    var lastUpdateCheckDate: Date? { didSet { stateDidChange?() } }
    var stateDidChange: (@MainActor () -> Void)?
    private(set) var startCount = 0
    private(set) var checkCount = 0

    func start() {
        startCount += 1
        stateDidChange?()
    }

    func checkForUpdates() {
        checkCount += 1
    }
}

private enum TestUpdateError: Error {
    case installationStopped
}

private let pendingRestoreKey = "EasyTierPendingSoftwareUpdateRuntimeRestore"

private func makeUserDefaults() -> (defaults: UserDefaults, clear: () -> Void) {
    let suiteName = "SoftwareUpdateControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
}
