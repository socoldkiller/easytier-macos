import Foundation
import Testing
@testable import EasyTierMac

@MainActor
@Test func authenticationCompletionRestoresAnInactiveMainWindow() {
    let window = TestNetworkSecretWindowPresentationTarget(role: .main)
    let application = TestNetworkSecretApplicationPresenter(
        isActive: true,
        keyWindow: window,
        windows: [window]
    )
    let coordinator = NetworkSecretAuthenticationPresentationCoordinator(
        applicationPresenter: application
    )
    let id = UUID()

    coordinator.networkSecretAuthenticationDidBegin(id: id)
    application.isActive = false
    application.keyWindow = nil
    coordinator.networkSecretAuthenticationDidEnd(id: id)

    #expect(application.restoredWindows.count == 1)
    #expect(application.restoredWindows.first === window)
}

@MainActor
@Test func concurrentAuthenticationRestoresOnlyAfterTheLastContextEnds() {
    let window = TestNetworkSecretWindowPresentationTarget(role: .main)
    let application = TestNetworkSecretApplicationPresenter(
        isActive: true,
        keyWindow: window,
        windows: [window]
    )
    let coordinator = NetworkSecretAuthenticationPresentationCoordinator(
        applicationPresenter: application
    )
    let firstID = UUID()
    let secondID = UUID()

    coordinator.networkSecretAuthenticationDidBegin(id: firstID)
    coordinator.networkSecretAuthenticationDidBegin(id: secondID)
    application.isActive = false
    application.keyWindow = nil

    coordinator.networkSecretAuthenticationDidEnd(id: firstID)
    #expect(application.restoredWindows.isEmpty)

    coordinator.networkSecretAuthenticationDidEnd(id: secondID)
    #expect(application.restoredWindows.count == 1)
}

@MainActor
@Test func authenticationDoesNotRestoreAWindowAfterTheApplicationWasHidden() {
    let window = TestNetworkSecretWindowPresentationTarget(role: .main)
    let application = TestNetworkSecretApplicationPresenter(
        isActive: true,
        keyWindow: window,
        windows: [window]
    )
    let coordinator = NetworkSecretAuthenticationPresentationCoordinator(
        applicationPresenter: application
    )
    let id = UUID()

    coordinator.networkSecretAuthenticationDidBegin(id: id)
    application.isActive = false
    application.isHidden = true
    application.keyWindow = nil
    coordinator.networkSecretAuthenticationDidEnd(id: id)

    #expect(application.restoredWindows.isEmpty)
}

@MainActor
@Test func backgroundAuthenticationNeverCapturesTheMainWindow() {
    let window = TestNetworkSecretWindowPresentationTarget(role: .main)
    let application = TestNetworkSecretApplicationPresenter(
        isActive: false,
        keyWindow: nil,
        windows: [window]
    )
    let coordinator = NetworkSecretAuthenticationPresentationCoordinator(
        applicationPresenter: application
    )
    let id = UUID()

    coordinator.networkSecretAuthenticationDidBegin(id: id)
    coordinator.networkSecretAuthenticationDidEnd(id: id)

    #expect(application.restoredWindows.isEmpty)
}

@MainActor
private final class TestNetworkSecretApplicationPresenter: NetworkSecretApplicationPresenting {
    var isActive: Bool
    var isHidden = false
    var keyWindow: (any NetworkSecretWindowPresentationTarget)?
    var windows: [any NetworkSecretWindowPresentationTarget]
    private(set) var restoredWindows: [any NetworkSecretWindowPresentationTarget] = []

    init(
        isActive: Bool,
        keyWindow: (any NetworkSecretWindowPresentationTarget)?,
        windows: [any NetworkSecretWindowPresentationTarget]
    ) {
        self.isActive = isActive
        self.keyWindow = keyWindow
        self.windows = windows
    }

    func restoreWindow(_ window: any NetworkSecretWindowPresentationTarget) {
        restoredWindows.append(window)
    }
}

@MainActor
private final class TestNetworkSecretWindowPresentationTarget: NetworkSecretWindowPresentationTarget {
    let easyTierWindowRole: EasyTierWindowRole?
    var isVisible = true
    var isMiniaturized = false
    var isKeyWindow = false
    var isMainWindow = false
    weak var parent: TestNetworkSecretWindowPresentationTarget?

    init(role: EasyTierWindowRole?) {
        easyTierWindowRole = role
    }

    var authenticationSheetParent: (any NetworkSecretWindowPresentationTarget)? {
        parent
    }
}
