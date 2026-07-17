import Testing
@testable import EasyTierMac

@MainActor
@Test func sparkleDelegateBridgeForwardsFrameworkIndependentEvents() {
    let delegate = TestSoftwareUpdateClientDelegate()
    let bridge = SparkleSoftwareUpdateDelegateBridge(delegate: delegate)

    #expect(bridge.allowedChannels == ["nightly"])

    var installHandlerCount = 0
    let postponed = bridge.postponeInstallation(targetBuild: "200") {
        installHandlerCount += 1
    }
    bridge.didAbort(with: TestSoftwareUpdateAdapterError.installationStopped)

    #expect(postponed)
    #expect(delegate.targetBuilds == ["200"])
    #expect(installHandlerCount == 1)
    #expect(delegate.abortCount == 1)
}

@MainActor
@Test func sparkleClientStartsOnlyWithCompleteNonemptyConfiguration() {
    #expect(!SparkleSoftwareUpdateClient.hasRequiredConfiguration(nil))
    #expect(!SparkleSoftwareUpdateClient.hasRequiredConfiguration([
        "SUFeedURL": "https://example.com/appcast.xml",
        "SUPublicEDKey": "",
    ]))
    #expect(!SparkleSoftwareUpdateClient.hasRequiredConfiguration([
        "SUFeedURL": "   ",
        "SUPublicEDKey": "public-key",
    ]))
    #expect(SparkleSoftwareUpdateClient.hasRequiredConfiguration([
        "SUFeedURL": "https://example.com/appcast.xml",
        "SUPublicEDKey": "public-key",
    ]))
}

@MainActor
private final class TestSoftwareUpdateClientDelegate: SoftwareUpdateClientDelegate {
    let allowedChannels: Set<String> = ["nightly"]
    private(set) var targetBuilds: [String] = []
    private(set) var abortCount = 0

    func shouldPostponeInstallation(
        targetBuild: String,
        installHandler: @escaping () -> Void
    ) -> Bool {
        targetBuilds.append(targetBuild)
        installHandler()
        return true
    }

    func softwareUpdateDidAbort(with error: Error) {
        _ = error
        abortCount += 1
    }
}

private enum TestSoftwareUpdateAdapterError: Error {
    case installationStopped
}
