import EasyTierShared
import Foundation
import Observation

protocol GatewayConnectionMonitoring: Sendable {
    func connectionEvents() -> AsyncStream<PrivilegedHelperConnectionEvent>
    func probeHelperAvailability() async throws
}

extension PrivilegedGatewayClient: GatewayConnectionMonitoring {}

@MainActor
@Observable
final class GatewayRuntimeController {
    private(set) var persistedState: GatewayPersistedState?
    private(set) var status: GatewayStatus = .stopped
    private(set) var lastError: String?
    private(set) var isBusy = false

    var desiredEnabled: Bool { persistedState?.enabled == true }

    @ObservationIgnored private let client: any GatewayClient
    @ObservationIgnored private let configurationStore: any GatewayConfigurationStoring
    @ObservationIgnored let helperRegistration: HelperRegistrationService?
    @ObservationIgnored private let connectionMonitor: (any GatewayConnectionMonitoring)?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryEnabled = false
    @ObservationIgnored private var mutationLocked = false
    @ObservationIgnored private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        client: any GatewayClient,
        configurationStore: any GatewayConfigurationStoring,
        helperRegistration: HelperRegistrationService?,
        connectionMonitor: (any GatewayConnectionMonitoring)? = nil
    ) {
        self.client = client
        self.configurationStore = configurationStore
        self.helperRegistration = helperRegistration
        self.connectionMonitor = connectionMonitor
    }

    func load() async {
        await withMutation {
            do {
                persistedState = try await configurationStore.load()
                if let persistedState {
                    let normalized = try GatewayConfigurationValidator.validate(
                        persistedState.configuration
                    )
                    self.persistedState?.configuration = normalized
                }
                lastError = nil
            } catch {
                persistedState = nil
                status = .stopped
                lastError = error.localizedDescription
            }
        }
    }

    func startConnectionRecovery() {
        guard connectionTask == nil, let connectionMonitor else { return }
        recoveryEnabled = true
        let events = connectionMonitor.connectionEvents()
        connectionTask = Task { [weak self] in
            for await _ in events {
                guard !Task.isCancelled, let self else { return }
                await self.recoverAfterConnectionEvent()
            }
        }
    }

    func reconcile() async {
        await withMutation {
            await reconcileWithoutLock()
        }
    }

    func setConfiguration(_ configuration: GatewayConfiguration, enabled: Bool) async throws {
        let normalized = try GatewayConfigurationValidator.validate(configuration)
        try await withMutation {
            let state = GatewayPersistedState(enabled: enabled, configuration: normalized)
            try await configurationStore.save(state)
            persistedState = state
            if enabled {
                await reconcileWithoutLock()
            } else {
                await stopWithoutLock()
            }
        }
    }

    func setEnabled(_ enabled: Bool) async throws {
        try await withMutation {
            guard var state = persistedState else {
                throw GatewayConfigurationValidationError.invalid(
                    "Save a Gateway configuration before enabling it."
                )
            }
            state.enabled = enabled
            try await configurationStore.save(state)
            persistedState = state
            if enabled {
                await reconcileWithoutLock()
            } else {
                await stopWithoutLock()
            }
        }
    }

    func refreshStatus() async {
        await withMutation {
            await refreshStatusWithoutLock()
        }
    }

    func requestRenewal(certificateID: String?) async {
        await withMutation {
            guard desiredEnabled else { return }
            isBusy = true
            defer { isBusy = false }
            do {
                try await client.requestRenewal(certificateID: certificateID)
                await refreshStatusWithoutLock()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func stopForLifecycle() async {
        suspendConnectionRecovery()
        await withMutation {
            guard desiredEnabled || status.state != .stopped else { return }
            await stopWithoutLock()
        }
    }

    func resumeAfterLifecycle() async {
        startConnectionRecovery()
        await reconcile()
    }

    private func reconcileWithoutLock() async {
        guard let persistedState, persistedState.enabled else {
            status = .stopped
            return
        }

        isBusy = true
        status.state = .starting
        defer { isBusy = false }
        do {
            if let helperRegistration {
                try await helperRegistration.ensureRegistered()
            }
            try await connectionMonitor?.probeHelperAvailability()
            try await client.start(configuration: persistedState.configuration)
            status = try await client.status()
            lastError = nil
        } catch {
            status.state = .failed
            status.lastError = error.localizedDescription
            lastError = error.localizedDescription
        }
    }

    private func stopWithoutLock() async {
        isBusy = true
        status.state = .stopping
        defer { isBusy = false }
        do {
            try await client.stop()
            status = .stopped
            lastError = nil
        } catch {
            status.state = .failed
            status.lastError = error.localizedDescription
            lastError = error.localizedDescription
        }
    }

    private func refreshStatusWithoutLock() async {
        do {
            status = try await client.status()
            lastError = status.lastError
        } catch {
            status.state = .failed
            status.lastError = error.localizedDescription
            lastError = error.localizedDescription
        }
    }

    private func recoverAfterConnectionEvent() async {
        guard recoveryEnabled, desiredEnabled else { return }
        do {
            try await Task.sleep(for: .seconds(1))
            try Task.checkCancellation()
        } catch {
            return
        }
        guard recoveryEnabled else { return }
        await withMutation {
            guard recoveryEnabled, !Task.isCancelled, desiredEnabled else { return }
            await reconcileWithoutLock()
        }
    }

    private func suspendConnectionRecovery() {
        recoveryEnabled = false
        connectionTask?.cancel()
        connectionTask = nil
    }

    private func withMutation<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        if mutationLocked {
            await withCheckedContinuation { continuation in
                mutationWaiters.append(continuation)
            }
        } else {
            mutationLocked = true
        }

        defer {
            if mutationWaiters.isEmpty {
                mutationLocked = false
            } else {
                mutationWaiters.removeFirst().resume()
            }
        }
        return try await operation()
    }
}

final class DisabledGatewayClient: GatewayClient, Sendable {
    func start(configuration: GatewayConfiguration) async throws {}
    func apply(configuration: GatewayConfiguration) async throws {}
    func stop() async throws {}
    func status() async throws -> GatewayStatus { .stopped }
    func requestRenewal(certificateID: String?) async throws {}
}
