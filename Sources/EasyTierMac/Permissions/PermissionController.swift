import EasyTierShared
import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class PermissionController {
    private(set) var state: PermissionState = .notRegistered
    private(set) var detail: String = "Privileged helper is not installed."
    private let service = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName)

    func refresh() {
        switch service.status {
        case .notRegistered:
            state = .notRegistered
            detail = "Install the privileged helper before starting TUN networking."
        case .enabled:
            state = .enabled
            detail = "Privileged helper is enabled."
        case .requiresApproval:
            state = .requiresApproval
            detail = "Approve EasyTier in System Settings to enable TUN networking."
        case .notFound:
            state = .notFound
            detail = "Privileged helper registration is not initialized. Install the helper before starting TUN networking."
        @unknown default:
            state = .error
            detail = "Unknown privileged helper status."
        }
    }

    func install() {
        do {
            try service.register()
            refresh()
        } catch {
            refreshAfterRegistrationFailure(error)
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshAfterRegistrationFailure(_ error: Error) {
        refresh()
        if state == .error || state == .notRegistered || state == .notFound {
            state = .error
            detail = error.localizedDescription
        }
    }
}
