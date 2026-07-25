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
    private let helperName: String
    private var didAttemptEnabledRepair = false

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
        self.helperName = "EasyTier helper"
        Task { await refreshAsync() }
    }

    package init(kind: PrivilegedHelperKind) {
        switch kind {
        case .easyTier:
            let service = SMAppService.daemon(
                plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName
            )
            self.backend = Self.liveBackend(service: service)
        case .gateway:
            let service = SMAppService.daemon(
                plistName: GatewayPrivilegedHelperConstants.launchDaemonPlistName
            )
            self.backend = Self.liveGatewayBackend(service: service)
        }
        self.helperName = kind.displayName
        Task { await refreshAsync() }
    }

    init(backend: Backend, refreshOnInit: Bool = true) {
        self.backend = backend
        self.helperName = "Privileged helper"
        if refreshOnInit {
            Task { await refreshAsync() }
        }
    }

    /// Ensure the privileged helper is installed, approved, reachable, and protocol-compatible.
    public func ensureRegistered() async throws {
        await refreshAsync()
        var repairingEnabledHelper = false
        switch state {
        case .enabled:
            do {
                try await backend.probeHelper()
                return
            } catch let error as CancellationError {
                throw error
            } catch {
                guard !didAttemptEnabledRepair else {
                    await refreshAfterRegistrationFailure(error)
                    throw error
                }
                didAttemptEnabledRepair = true
                repairingEnabledHelper = true
                break
            }
        case .registering:
            await waitForBusy()
            await refreshAsync()
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
        detail = "Registering \(helperName)..."

        do {
            _ = try? await backend.unregister()
            if repairingEnabledHelper {
                try await backend.waitAfterUnregister()
            }
            try await backend.register()
            try await backend.probeHelper()
            state = .enabled
            detail = "\(helperName) is enabled."
        } catch {
            await refreshAfterRegistrationFailure(error)
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
        let status = await backend.status()
        switch status {
        case .notRegistered:
            state = .notRegistered
            detail = "\(helperName) is not installed. The app will request permission when it is needed."
        case .enabled:
            state = .enabled
            detail = "\(helperName) is enabled."
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

    private func refreshAfterRegistrationFailure(_ error: Error) async {
        let message = error.localizedDescription
        let status = await backend.status()
        if status == .requiresApproval || message.localizedCaseInsensitiveContains("operation not permitted") {
            state = .requiresApproval
            detail = "Approve EasyTier in System Settings to enable network runtime operations."
            return
        }
        state = .error
        detail = message
    }

    struct Backend {
        var status: @MainActor () async -> SMAppService.Status
        var register: @MainActor () async throws -> Void
        var unregister: @MainActor () async throws -> Void
        var waitAfterUnregister: @MainActor () async throws -> Void
        var canInstallHelper: @MainActor () -> Bool
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

    private static func liveBackend(service: SMAppService) -> Backend {
        let box = ServiceBox(service: service)
        return Backend(
            status: { await Self.readServiceStatus(box) },
            register: { try await Self.serviceRegister(box) },
            unregister: { try await Self.serviceUnregister(box) },
            waitAfterUnregister: { try await Task.sleep(for: .seconds(1)) },
            canInstallHelper: { Self.currentBundleCanInstallHelper },
            probeHelper: { try await Self.validateModernHelper() }
        )
    }

    private static func liveGatewayBackend(service: SMAppService) -> Backend {
        let box = ServiceBox(service: service)
        return Backend(
            status: { await Self.readServiceStatus(box) },
            register: { try await Self.serviceRegister(box) },
            unregister: { try await Self.serviceUnregister(box) },
            waitAfterUnregister: { try await Task.sleep(for: .seconds(1)) },
            canInstallHelper: { Self.currentBundleCanInstallHelper },
            probeHelper: { try await Self.validateGatewayHelper() }
        )
    }

    private nonisolated static func validateModernHelper() async throws {
        let client = PrivilegedEasyTierClient()
        try await client.probeHelperAvailability()
        let installed = try await client.helperBuildInfo()
        let bundled = try PrivilegedHelperBuildInfo(bundle: .main)
        guard modernHelperBuildMatches(installed: installed, bundled: bundled) else {
            throw PrivilegedHelperError.helperReported(
                PrivilegedHelperErrorPayload(
                    code: "helperBuildMismatch",
                    message: "Privileged helper build \(installed.binaryDisplay) does not match this app build \(bundled.binaryDisplay).",
                    recoverySuggestion: "Reinstall the privileged helper from this EasyTier app."
                )
            )
        }
    }

    private nonisolated static func validateGatewayHelper() async throws {
        let client = PrivilegedGatewayClient()
        try await client.probeHelperAvailability()
        let installed = try await client.helperBuildInfo()
        let bundled = try GatewayHelperBuildInfo(bundle: .main)
        guard gatewayHelperBuildMatches(installed: installed, bundled: bundled) else {
            throw PrivilegedHelperError.helperReported(
                PrivilegedHelperErrorPayload(
                    code: "helperBuildMismatch",
                    message: "Gateway helper build \(installed.binaryDisplay) does not match this app build \(bundled.binaryDisplay).",
                    recoverySuggestion: "Reinstall the Gateway helper from this app."
                )
            )
        }
    }

    nonisolated static func modernHelperBuildMatches(
        installed: PrivilegedHelperBuildInfo,
        bundled: PrivilegedHelperBuildInfo
    ) -> Bool {
        installed.version == bundled.version
            && installed.build == bundled.build
            && installed.protocolVersion == bundled.protocolVersion
            && installed.guiCommit == bundled.guiCommit
    }

    nonisolated static func gatewayHelperBuildMatches(
        installed: GatewayHelperBuildInfo,
        bundled: GatewayHelperBuildInfo
    ) -> Bool {
        installed.build == bundled.build
            && installed.gatewayVersion == bundled.gatewayVersion
            && installed.protocolVersion == bundled.protocolVersion
            && installed.schemaVersion == bundled.schemaVersion
            && installed.gatewayCommit == bundled.gatewayCommit
    }
}

private struct ServiceBox: @unchecked Sendable {
    let service: SMAppService
}
