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
        Task { await refreshAsync() }
    }

    /// Register the privileged helper only when it is about to be used.
    /// Throws `PrivilegedHelperError.needsRegistration` if registration cannot complete.
    public func ensureRegistered() async throws {
        let useLegacy = await Self.readShouldUseLegacyInstaller()
        await refreshAsync(useLegacy: useLegacy)
        switch state {
        case .enabled:
            return
        case .registering:
            await waitForBusy()
            await refreshAsync(useLegacy: useLegacy)
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
            if useLegacy {
                _ = try? await Self.serviceUnregister(serviceBox)
                try await Self.installLegacy()
            } else {
                _ = try? await Self.serviceUnregister(serviceBox)
                try await Self.serviceRegister(serviceBox)
            }
            await refreshAsync(useLegacy: useLegacy)
            if state != .enabled {
                throw PrivilegedHelperError.needsRegistration
            }
        } catch {
            await refreshAfterRegistrationFailure(error, useLegacy: useLegacy)
            throw PrivilegedHelperError.needsRegistration
        }
    }

    /// Reflect SystemSettings changes without side effects. Safe to call on scenePhase change.
    public func refresh() async {
        await refreshAsync()
    }

    public func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Internals

    private func refreshAsync() async {
        let useLegacy = await Self.readShouldUseLegacyInstaller()
        await refreshAsync(useLegacy: useLegacy)
    }

    private func refreshAsync(useLegacy: Bool) async {
        if useLegacy {
            let installed = await Self.readLegacyIsInstalled()
            if installed {
                state = .enabled
                detail = "Privileged helper is enabled."
            } else {
                state = .notRegistered
                detail = "Privileged helper is not installed. Starting a TUN network will prompt for administrator permission."
            }
            return
        }

        let status = await Self.readServiceStatus(serviceBox)
        switch status {
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

    private func refreshAfterRegistrationFailure(_ error: Error, useLegacy: Bool) async {
        let message = error.localizedDescription
        if useLegacy {
            state = .error
            detail = message
            return
        }
        let status = await Self.readServiceStatus(serviceBox)
        if status == .requiresApproval || message.localizedCaseInsensitiveContains("operation not permitted") {
            state = .requiresApproval
            detail = "Approve EasyTier in System Settings to enable TUN networking."
            return
        }
        state = .error
        detail = message
    }

    private var serviceBox: ServiceBox { ServiceBox(service: service) }

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

    // MARK: - Background execution helpers
    // These run blocking calls (XPC to smd, Process.waitUntilExit, codesign, launchctl)
    // off the main actor so the UI never freezes.

    private nonisolated static func readServiceStatus(_ box: ServiceBox) async -> SMAppService.Status {
        await Task.detached { @Sendable in box.service.status }.value
    }

    private nonisolated static func serviceRegister(_ box: ServiceBox) async throws {
        try await Task.detached { @Sendable in try box.service.register() }.value
    }

    private nonisolated static func serviceUnregister(_ box: ServiceBox) async throws {
        try await Task.detached { @Sendable in try box.service.unregister() }.value
    }

    private nonisolated static func readShouldUseLegacyInstaller() async -> Bool {
        await Task.detached { @Sendable in LegacyPrivilegedHelperService.shouldUseLegacyInstaller }.value
    }

    private nonisolated static func readLegacyIsInstalled() async -> Bool {
        await Task.detached { @Sendable in LegacyPrivilegedHelperService.isInstalled }.value
    }

    private nonisolated static func installLegacy() async throws {
        try await Task.detached { @Sendable in try LegacyPrivilegedHelperService.installUsingAdministratorPrivileges() }.value
    }
}

private struct ServiceBox: @unchecked Sendable {
    let service: SMAppService
}
