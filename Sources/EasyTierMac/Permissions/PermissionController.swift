import EasyTierShared
import AppKit
import Foundation
import Observation
import Security
import ServiceManagement

@MainActor
@Observable
final class PermissionController {
    private(set) var state: PermissionState = .notRegistered
    private(set) var detail: String = "Privileged helper is not installed."
    private(set) var isBusy = false
    private let service = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName)

    func refresh() async {
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
            try? await service.unregister()
            try service.register()
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
        try? await service.unregister()
        try? Self.resetBackgroundTaskManagementState()

        do {
            try service.register()
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
        helperInstallPreflightError() == nil
    }

    private static var unstableBundleLocationMessage: String {
        helperInstallPreflightError() ?? "EasyTier cannot install the privileged helper from this app bundle."
    }

    private static func helperInstallPreflightError() -> String? {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        guard path == "/Applications/EasyTier.app" else {
            return "Move EasyTier.app to /Applications/EasyTier.app before installing the privileged helper. Running from \(path) can leave macOS with a stale helper registration."
        }
        guard currentCodeSignatureTeamID != nil else {
            return "This EasyTier build is self-signed and cannot install the privileged helper because its code signature has no Apple Team ID. Use an Apple Development or Developer ID signed build for TUN networking, or switch this network to no_tun."
        }
        return nil
    }

    private static var currentCodeSignatureTeamID: String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        ) == errSecSuccess, let info else { return nil }

        let dictionary = info as NSDictionary
        guard let teamID = dictionary[kSecCodeInfoTeamIdentifier] as? String else { return nil }
        let trimmed = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
