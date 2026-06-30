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
    private(set) var isBusy = false
    private let service = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName)

    func refresh() async {
        if LegacyPrivilegedHelperService.shouldUseLegacyInstaller {
            if LegacyPrivilegedHelperService.isInstalled {
                await verifyEnabledHelper()
            } else {
                state = .notRegistered
                detail = "Install the privileged helper with administrator permission before starting TUN networking."
            }
            return
        }

        switch service.status {
        case .notRegistered:
            state = .notRegistered
            detail = "Install the privileged helper before starting TUN networking."
        case .enabled:
            await verifyEnabledHelper()
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

    func install() async {
        guard !isBusy else { return }
        guard Self.currentBundleCanInstallHelper else {
            state = .error
            detail = Self.unstableBundleLocationMessage
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            if LegacyPrivilegedHelperService.shouldUseLegacyInstaller {
                try LegacyPrivilegedHelperService.installUsingAdministratorPrivileges()
            } else {
                try? await service.unregister()
                try service.register()
            }
            await refresh()
        } catch {
            refreshAfterRegistrationFailure(error)
        }
    }

    func repair() async {
        guard !isBusy else { return }
        guard Self.currentBundleCanInstallHelper else {
            state = .error
            detail = Self.unstableBundleLocationMessage
            return
        }

        isBusy = true
        defer { isBusy = false }

        detail = "Repairing privileged helper registration..."

        do {
            if LegacyPrivilegedHelperService.shouldUseLegacyInstaller {
                try LegacyPrivilegedHelperService.installUsingAdministratorPrivileges()
            } else {
                try? await service.unregister()
                try? Self.resetBackgroundTaskManagementState()
                try service.register()
            }
            await refresh()
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
        let message = error.localizedDescription
        if service.status == .requiresApproval || message.localizedCaseInsensitiveContains("operation not permitted") {
            state = .requiresApproval
            detail = "Approve EasyTier in System Settings to enable TUN networking."
            return
        }

        state = .error
        detail = message
    }

    private func verifyEnabledHelper() async {
        do {
            let payload = try await PrivilegedEasyTierClient().helperPingPayload()
            guard payload == EasyTierPrivilegedHelperConstants.pingPayload else {
                state = .error
                detail = "Privileged helper replied with an unexpected protocol. Repair the helper before starting TUN networking."
                return
            }
            state = .enabled
            detail = "Privileged helper is enabled."
        } catch {
            state = .error
            detail = Self.helperHealthFailureMessage(for: error)
        }
    }

    private static var currentBundleCanInstallHelper: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path == "/Applications/EasyTier.app"
    }

    private static var unstableBundleLocationMessage: String {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return "Move EasyTier.app to /Applications/EasyTier.app before installing the privileged helper. Running from \(path) can leave macOS with a stale helper registration."
    }

    private static func helperHealthFailureMessage(for error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return "Privileged helper is registered but is not responding. Repair the helper before starting TUN networking. \(message)"
    }

    private static func resetBackgroundTaskManagementState() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sfltool")
        process.arguments = ["resetbtm"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad)
        }
    }
}
