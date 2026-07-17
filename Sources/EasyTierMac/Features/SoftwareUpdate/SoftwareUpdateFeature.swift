import Foundation

@MainActor
struct SoftwareUpdateFeature {
    let controller: SoftwareUpdateController

    init(
        runtime: any SoftwareUpdateRuntimeManaging,
        privilegedHelper: any PrivilegedHelperLifecycle,
        userDefaults: UserDefaults,
        currentBuild: String = AppVersionInfo.current.rawBuild,
        clientFactory: @escaping SoftwareUpdateController.ClientFactory
    ) {
        controller = SoftwareUpdateController(
            userDefaults: userDefaults,
            currentBuild: currentBuild,
            clientFactory: clientFactory,
            captureRunningConfigIDs: {
                runtime.runningConfigIDsForSoftwareUpdate()
            },
            prepareForInstallation: {
                await runtime.prepareForSoftwareUpdate()
                do {
                    try await privilegedHelper.unregister()
                    runtime.recordNotice("Privileged helper unregistered for software update.")
                } catch {
                    runtime.recordNotice(
                        "Privileged helper unregister before software update was skipped: \(error.localizedDescription)"
                    )
                }
            },
            restoreRunningConfigIDs: { configIDs in
                await runtime.restoreConfigsAfterSoftwareUpdate(configIDs: configIDs)
            },
            recordNotice: { message in
                runtime.recordNotice(message)
            }
        )
    }
}
