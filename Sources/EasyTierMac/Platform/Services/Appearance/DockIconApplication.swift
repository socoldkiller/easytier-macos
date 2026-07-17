import AppKit

@MainActor
protocol DockIconApplication: AnyObject {
    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool
    func activate(ignoringOtherApps flag: Bool)
}

extension NSApplication: DockIconApplication {}
