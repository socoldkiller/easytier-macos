import Foundation
import Sparkle

@MainActor
final class SparkleSoftwareUpdateDelegateBridge: NSObject, SPUUpdaterDelegate {
    private weak var delegate: (any SoftwareUpdateClientDelegate)?

    init(delegate: any SoftwareUpdateClientDelegate) {
        self.delegate = delegate
    }

    var allowedChannels: Set<String> {
        delegate?.allowedChannels ?? []
    }

    func postponeInstallation(
        targetBuild: String,
        installHandler: @escaping () -> Void
    ) -> Bool {
        delegate?.shouldPostponeInstallation(
            targetBuild: targetBuild,
            installHandler: installHandler
        ) ?? false
    }

    func didAbort(with error: Error) {
        delegate?.softwareUpdateDidAbort(with: error)
    }

    func allowedChannels(for _: SPUUpdater) -> Set<String> {
        allowedChannels
    }

    func updater(
        _: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        postponeInstallation(
            targetBuild: item.versionString,
            installHandler: installHandler
        )
    }

    func updater(_: SPUUpdater, didAbortWithError error: Error) {
        didAbort(with: error)
    }
}
