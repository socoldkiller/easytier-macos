import AppKit
import Foundation
import Observation
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
        switch state {
        case .enabled:
            return
        case .registering:
            await waitForBusy()
            if state == .enabled { return }
        case .notRegistered, .requiresApproval, .notFound, .error:
            break
        }

        guard Self.currentBundleCanInstallHelper else {
            state = .error
            detail = Self.unstableBundleLocationMessage
            throw PrivilegedHelperError.needsRegistration
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
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path == "/Applications/EasyTier.app"
    }

    private static var unstableBundleLocationMessage: String {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return "Move EasyTier.app to /Applications/EasyTier.app before installing the privileged helper. Running from \(path) can leave macOS with a stale helper registration."
    }
}