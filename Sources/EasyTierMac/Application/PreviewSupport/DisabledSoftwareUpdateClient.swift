import Foundation

@MainActor
final class DisabledSoftwareUpdateClient: SoftwareUpdateClient {
    var canCheckForUpdates = false
    var sessionInProgress = false
    var automaticallyChecksForUpdates = false
    var lastUpdateCheckDate: Date?
    var stateDidChange: (@MainActor () -> Void)?

    func start() {
        stateDidChange?()
    }

    func checkForUpdates() {}
    func resetUpdateCycleAfterShortDelay() {}
}
