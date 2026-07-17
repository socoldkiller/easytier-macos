import AppKit

@MainActor
final class SystemDockIconVisibilityService: DockIconVisibilityApplying {
    typealias ApplicationProvider = @MainActor () -> any DockIconApplication

    private let applicationProvider: ApplicationProvider

    init(
        applicationProvider: @escaping ApplicationProvider = {
            NSApplication.shared
        }
    ) {
        self.applicationProvider = applicationProvider
    }

    init(application: any DockIconApplication) {
        applicationProvider = { application }
    }

    func applyDockIconVisibility(_ showsDockIcon: Bool) {
        let application = applicationProvider()
        guard application.setActivationPolicy(Self.activationPolicy(showsDockIcon: showsDockIcon)) else { return }
        application.activate(ignoringOtherApps: true)
    }

    static func activationPolicy(showsDockIcon: Bool) -> NSApplication.ActivationPolicy {
        showsDockIcon ? .regular : .accessory
    }
}
