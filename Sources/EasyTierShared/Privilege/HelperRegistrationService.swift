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

    private let backend: Backend

    public enum State: Equatable, Sendable {
        case notRegistered
        case registering
        case requiresApproval
        case enabled
        case notFound
        case error
    }

    public init() {
        let service = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName)
        self.backend = Self.liveBackend(service: service)
        Task { await refreshAsync() }
    }

    init(backend: Backend, refreshOnInit: Bool = true) {
        self.backend = backend
        if refreshOnInit {
            Task { await refreshAsync() }
        }
    }

    /// Ensure the privileged helper is installed, approved, reachable, and protocol-compatible.
    public func ensureRegistered() async throws {
        let useLegacy = await backend.useLegacyInstaller()
        await refreshAsync(useLegacy: useLegacy)
        switch state {
        case .enabled:
            do {
                try await backend.probeHelper()
                return
            } catch where Self.isProtocolMismatch(error) {
                break
            } catch {
                await refreshAfterRegistrationFailure(error, useLegacy: useLegacy)
                throw error
            }
        case .registering:
            await waitForBusy()
            await refreshAsync(useLegacy: useLegacy)
            if state == .enabled { return }
            if state == .requiresApproval { throw PrivilegedHelperError.needsRegistration }
        case .requiresApproval:
            throw PrivilegedHelperError.needsRegistration
        case .notRegistered, .notFound:
            break
        case .error:
            throw PrivilegedHelperError.needsRegistration
        }

        guard backend.canInstallHelper() else {
            state = .error
            detail = Self.unstableBundleLocationMessage
            throw PrivilegedHelperError.helperReported(
                PrivilegedHelperErrorPayload(
                    code: "helperUnstableBundleLocation",
                    message: detail,
                    recoverySuggestion: "Use the EasyTierMac-InstalledDebug scheme or move the signed app to /Applications/EasyTier.app."
                )
            )
        }

        isBusy = true
        defer { isBusy = false }
        state = .registering
        detail = "Registering privileged helper..."

        do {
            if useLegacy {
                _ = try? await backend.unregister()
                try await backend.installLegacy()
                await refreshAsync(useLegacy: true)
                if state != .enabled {
                    throw PrivilegedHelperError.needsRegistration
                }
            } else {
                _ = try? await backend.unregister()
                if await backend.legacyArtifactsExist() {
                    try await backend.uninstallLegacy()
                }
                try await backend.register()
                try await backend.probeHelper()
                state = .enabled
                detail = "Privileged helper is enabled."
            }
        } catch {
            await refreshAfterRegistrationFailure(error, useLegacy: useLegacy)
            if state == .requiresApproval {
                throw PrivilegedHelperError.needsRegistration
            }
            throw error
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
        let useLegacy = await backend.useLegacyInstaller()
        await refreshAsync(useLegacy: useLegacy)
    }

    private func refreshAsync(useLegacy: Bool) async {
        if useLegacy {
            let installed = await backend.legacyIsInstalled()
            if installed {
                state = .enabled
                detail = "Privileged helper is enabled."
            } else {
                state = .notRegistered
                detail = "Privileged helper is not installed. EasyTier will request administrator permission before running a network."
            }
            return
        }

        let status = await backend.status()
        switch status {
        case .notRegistered:
            state = .notRegistered
            detail = "Privileged helper is not installed. EasyTier will request permission before running a network."
        case .enabled:
            state = .enabled
            detail = "Privileged helper is enabled."
        case .requiresApproval:
            state = .requiresApproval
            detail = "Approve EasyTier in System Settings to enable network runtime operations."
        case .notFound:
            state = .notFound
            detail = "Privileged helper registration is not initialized. EasyTier will attempt to install it before running a network."
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
        let status = await backend.status()
        if status == .requiresApproval || message.localizedCaseInsensitiveContains("operation not permitted") {
            state = .requiresApproval
            detail = "Approve EasyTier in System Settings to enable network runtime operations."
            return
        }
        state = .error
        detail = message
    }

    private static func isProtocolMismatch(_ error: Error) -> Bool {
        guard case let PrivilegedHelperError.helperReported(payload) = error else { return false }
        return payload.code == "protocolMismatch"
    }

    struct Backend {
        var status: @MainActor () async -> SMAppService.Status
        var register: @MainActor () async throws -> Void
        var unregister: @MainActor () async throws -> Void
        var canInstallHelper: @MainActor () -> Bool
        var useLegacyInstaller: @MainActor () async -> Bool
        var legacyArtifactsExist: @MainActor () async -> Bool
        var legacyIsInstalled: @MainActor () async -> Bool
        var installLegacy: @MainActor () async throws -> Void
        var uninstallLegacy: @MainActor () async throws -> Void
        var probeHelper: @MainActor () async throws -> Void
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

    private nonisolated static func readLegacyArtifactsExist() async -> Bool {
        await Task.detached { @Sendable in LegacyPrivilegedHelperService.hasInstalledArtifacts }.value
    }

    private static func liveBackend(service: SMAppService) -> Backend {
        let box = ServiceBox(service: service)
        return Backend(
            status: { await Self.readServiceStatus(box) },
            register: { try await Self.serviceRegister(box) },
            unregister: { try await Self.serviceUnregister(box) },
            canInstallHelper: { Self.currentBundleCanInstallHelper },
            useLegacyInstaller: { await Self.readShouldUseLegacyInstaller() },
            legacyArtifactsExist: { await Self.readLegacyArtifactsExist() },
            legacyIsInstalled: { await Self.readLegacyIsInstalled() },
            installLegacy: { try await Self.installLegacy() },
            uninstallLegacy: { try await Self.uninstallLegacy() },
            probeHelper: { try await Self.probeModernHelper() }
        )
    }

    private nonisolated static func installLegacy() async throws {
        try await Task.detached { @Sendable in try LegacyPrivilegedHelperService.installUsingAdministratorPrivileges() }.value
    }

    private nonisolated static func uninstallLegacy() async throws {
        try await Task.detached { @Sendable in try LegacyPrivilegedHelperService.uninstallUsingAdministratorPrivileges() }.value
    }

    private nonisolated static func probeModernHelper() async throws {
        try await PrivilegedEasyTierClient().probeHelperAvailability()
    }
}

private struct ServiceBox: @unchecked Sendable {
    let service: SMAppService
}
