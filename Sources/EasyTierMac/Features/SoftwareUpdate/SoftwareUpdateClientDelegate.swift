@MainActor
protocol SoftwareUpdateClientDelegate: AnyObject {
    var allowedChannels: Set<String> { get }

    func shouldPostponeInstallation(
        targetBuild: String,
        installHandler: @escaping () -> Void
    ) -> Bool

    func softwareUpdateDidAbort(with error: Error)
}
