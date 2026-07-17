import Foundation

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
