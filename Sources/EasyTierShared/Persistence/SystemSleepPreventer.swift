import Foundation
import IOKit.pwr_mgt

public protocol SystemSleepPreventing: AnyObject, Sendable {
    var isPreventingSystemSleep: Bool { get }
    func setSystemSleepPrevented(_ prevented: Bool, reason: String)
}

public final class IOKitSystemSleepPreventer: SystemSleepPreventing, @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID = IOPMAssertionID(kIOPMNullAssertionID)

    public init() {}

    deinit {
        setSystemSleepPrevented(false, reason: "")
    }

    public var isPreventingSystemSleep: Bool {
        lock.lock()
        defer { lock.unlock() }
        return assertionID != IOPMAssertionID(kIOPMNullAssertionID)
    }

    public func setSystemSleepPrevented(_ prevented: Bool, reason: String) {
        lock.lock()
        defer { lock.unlock() }

        if prevented {
            guard assertionID == IOPMAssertionID(kIOPMNullAssertionID) else { return }
            var newAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoIdleSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &newAssertionID
            )
            if result == kIOReturnSuccess {
                assertionID = newAssertionID
            }
            return
        }

        guard assertionID != IOPMAssertionID(kIOPMNullAssertionID) else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(kIOPMNullAssertionID)
    }
}
