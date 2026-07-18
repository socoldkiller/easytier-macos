import AppKit
import Testing
@testable import EasyTierMac

@MainActor
@Test func applicationDelegateSeparatesFocusLossFromActualHiding() {
    let delegate = EasyTierApplicationDelegate()
    var becameActiveCount = 0
    var resignedActiveCount = 0
    var hiddenCount = 0
    delegate.installApplicationActivityHandlers(
        didBecomeActive: { becameActiveCount += 1 },
        didResignActive: { resignedActiveCount += 1 },
        didHide: { hiddenCount += 1 }
    )

    delegate.applicationDidBecomeActive(
        Notification(name: NSApplication.didBecomeActiveNotification)
    )
    delegate.applicationDidResignActive(
        Notification(name: NSApplication.didResignActiveNotification)
    )
    delegate.applicationDidHide(
        Notification(name: NSApplication.didHideNotification)
    )

    #expect(becameActiveCount == 1)
    #expect(resignedActiveCount == 1)
    #expect(hiddenCount == 1)
}
