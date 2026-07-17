import Foundation
import Sparkle

@MainActor
final class SparkleSoftwareUpdateClient: SoftwareUpdateClient {
    var stateDidChange: (@MainActor () -> Void)?

    private let delegateBridge: SparkleSoftwareUpdateDelegateBridge
    private let controller: SPUStandardUpdaterController
    private var observations: [NSKeyValueObservation] = []

    init(delegate: any SoftwareUpdateClientDelegate) {
        let delegateBridge = SparkleSoftwareUpdateDelegateBridge(delegate: delegate)
        self.delegateBridge = delegateBridge
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegateBridge,
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
        guard Self.hasRequiredConfiguration(Bundle.main.infoDictionary) else {
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

    static func hasRequiredConfiguration(_ infoDictionary: [String: Any]?) -> Bool {
        guard let feedURL = infoDictionary?["SUFeedURL"] as? String,
              let publicKey = infoDictionary?["SUPublicEDKey"] as? String
        else {
            return false
        }

        return !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
