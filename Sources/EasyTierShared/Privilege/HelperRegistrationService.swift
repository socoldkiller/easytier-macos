import AppKit
import Foundation
import Observation
import Security
import ServiceManagement

@MainActor
@Observable
public final class HelperRegistrationService {
    public private(set) var state: State = .notRegistered
    public private(set) var detail: String = ""
    public private(set) var isBusy = false

    private let service = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName)

    public enum State: Equatable, Sendable {
        case notRegistered
        case registering
        case requiresApproval
        case enabled
        case notFound
        case error
    }

    public init() {
        refreshSync()
    }

    /// Register the privileged helper only when it is about to be used.
    /// Throws `PrivilegedHelperError.needsRegistration` if registration cannot complete.
    public func ensureRegistered() async throws {
        refreshSync()
        switch state {
        case .enabled:
            return
        case .registering:
            await waitForBusy()
            refreshSync()
            if state == .enabled { return }
        case .notRegistered, .requiresApproval, .notFound, .error:
            break
        }

        if let preflightError = Self.helperInstallPreflightError() {
            state = .error
            detail = preflightError
            throw PrivilegedHelperError.helperReported(
                PrivilegedHelperErrorPayload(
                    code: "helperNotInstallable",
                    message: preflightError
                )
            )
        }

        isBusy = true
        defer { isBusy = false }
        state = .registering
        detail = "Registering privileged helper..."

        do {
            try? await service.unregister()
            try service.register()
            refreshSync()
            if state != .enabled {
                throw PrivilegedHelperError.needsRegistration
            }
        } catch {
            refreshAfterRegistrationFailure(error)
            throw PrivilegedHelperError.needsRegistration
        }
    }

    /// Reflect SystemSettings changes without side effects. Safe to call on scenePhase change.
    public func refresh() async {
        refreshSync()
    }

    public func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Internals

    private func refreshSync() {
        switch service.status {
        case .notRegistered:
            state = .notRegistered
            detail = "Privileged helper is not installed. Starting a TUN network will prompt for permission."
        case .enabled:
            state = .enabled
            detail = "Privileged helper is enabled."
        case .requiresApproval:
            state = .requiresApproval
            detail = "Approve EasyTier in System Settings to enable TUN networking."
        case .notFound:
            state = .notFound
            detail = "Privileged helper registration is not initialized. Starting a TUN network will attempt to install it."
        @unknown default:
            state = .error
            detail = "Unknown privileged helper status."
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

    private func waitForBusy() async {
        while isBusy {
            try? await Task.sleep(for: .milliseconds(50))
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
}
