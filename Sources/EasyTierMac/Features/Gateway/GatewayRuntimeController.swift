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

    var desiredEnabled: Bool { persistedState?.desiredEnabled == true }
    var services: [GatewayPublishedService] { persistedState?.services ?? [] }
    var publishingNetworkConfigID: String? { persistedState?.publishingNetworkConfigID }
    var acmeConfiguration: GatewayACMEConfiguration? { persistedState?.acmeAccount }
    var isTLSConfigured: Bool { acmeConfiguration?.termsOfServiceAgreed == true }

    @ObservationIgnored private let client: any GatewayClient
    @ObservationIgnored private let configurationStore: any GatewayConfigurationStoring
    @ObservationIgnored let helperRegistration: HelperRegistrationService?
    @ObservationIgnored private let connectionMonitor: (any GatewayConnectionMonitoring)?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryEnabled = false
    @ObservationIgnored private var retainsRuntimeAfterDisconnect = false
    @ObservationIgnored private var lastAppliedConfiguration: GatewayConfiguration?
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
                persistedState = try await configurationStore.load() ?? .empty
                lastError = nil
            } catch {
                persistedState = .empty
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

    func createDraft(
        networkConfigID: String,
        targetPeerID: String,
        targetHostname: String,
        magicDNSSuffix: String,
        serviceLabel: String,
        targetPort: Int
    ) async throws -> GatewayPublishedService {
        let draft = try GatewayPublishedServicesValidator.makeDraft(
            networkConfigID: networkConfigID,
            targetPeerID: targetPeerID,
            targetHostname: targetHostname,
            magicDNSSuffix: magicDNSSuffix,
            serviceLabel: serviceLabel,
            targetPort: targetPort
        )
        return try await withMutation {
            var state = persistedState ?? .empty
            if let owner = state.publishingNetworkConfigID, owner != networkConfigID {
                throw GatewayConfigurationValidationError.invalid(
                    "Published Services already belongs to another EasyTier network."
                )
            }
            guard !state.services.contains(where: { $0.publicHostname == draft.publicHostname }) else {
                throw GatewayConfigurationValidationError.invalid(
                    "A service already uses \(draft.publicHostname)."
                )
            }
            state.publishingNetworkConfigID = networkConfigID
            state.services.append(draft)
            try await save(state)
            return draft
        }
    }

    func configureACME(contactEmail: String?, termsOfServiceAgreed: Bool) async throws {
        try await withMutation {
            var state = persistedState ?? .empty
            state.acmeAccount = GatewayACMEConfiguration(
                directory: .letsencryptProduction,
                contactEmail: contactEmail,
                termsOfServiceAgreed: termsOfServiceAgreed
            )
            try await save(state)
            if state.desiredEnabled {
                await reconcileWithoutLock()
                if status.state == .failed {
                    throw EasyTierCoreError.operationFailed(
                        lastError ?? "Gateway failed to apply the TLS settings."
                    )
                }
            }
        }
    }

    func setGatewayEnabled(_ enabled: Bool) async throws {
        try await withMutation {
            var state = persistedState ?? .empty
            guard state.gatewayEnabled != enabled else {
                await reconcileWithoutLock()
                return
            }
            state.gatewayEnabled = enabled
            try await save(state)
            await reconcileWithoutLock()
            if status.state == .failed {
                throw EasyTierCoreError.operationFailed(
                    lastError ?? "Gateway failed to \(enabled ? "start" : "stop")."
                )
            }
        }
    }

    func setServiceEnabled(_ enabled: Bool, serviceID: String) async throws {
        try await withMutation {
            guard var state = persistedState,
                  let index = state.services.firstIndex(where: { $0.id == serviceID })
            else {
                throw GatewayConfigurationValidationError.invalid("Published service was not found.")
            }
            guard state.services[index].desiredEnabled != enabled else { return }
            if enabled {
                guard let acme = state.acmeAccount, acme.termsOfServiceAgreed else {
                    throw GatewayConfigurationValidationError.invalid(
                        "Accept the Let's Encrypt terms before enabling this service."
                    )
                }
                guard state.lastKnownNetworkIPv4CIDR != nil else {
                    throw GatewayConfigurationValidationError.invalid(
                        "Wait for the publishing EasyTier network to report its IPv4 subnet."
                    )
                }
            }
            state.services[index].desiredEnabled = enabled
            try await save(state)
            await reconcileWithoutLock()
            if state.gatewayEnabled, status.state == .failed {
                throw EasyTierCoreError.operationFailed(
                    lastError ?? "Gateway failed to apply the published service."
                )
            }
        }
    }

    func updatePort(serviceID: String, port: Int) async throws {
        try await withMutation {
            guard var state = persistedState,
                  let index = state.services.firstIndex(where: { $0.id == serviceID })
            else {
                throw GatewayConfigurationValidationError.invalid("Published service was not found.")
            }
            var updated = state.services[index]
            updated.targetPort = port
            state.services[index] = updated
            try await save(state)
            await reconcileWithoutLock()
        }
    }

    func deleteService(_ serviceID: String) async throws {
        try await withMutation {
            guard var state = persistedState else { return }
            state.services.removeAll { $0.id == serviceID }
            if state.services.isEmpty {
                state.publishingNetworkConfigID = nil
                state.lastKnownNetworkIPv4CIDR = nil
            }
            try await save(state)
            await reconcileWithoutLock()
        }
    }

    func reconcileTopology(
        networkConfigID: String,
        allowedIPv4CIDR: String?,
        magicDNSSuffix: String,
        hostnamesByPeerID: [String: String]
    ) async {
        await withMutation {
            guard var state = persistedState,
                  state.publishingNetworkConfigID == networkConfigID
            else { return }

            var changed = false
            if let allowedIPv4CIDR,
               let normalizedCIDR = try? GatewayPublishedServicesValidator.normalizeIPv4CIDR(
                   allowedIPv4CIDR
               ),
               state.lastKnownNetworkIPv4CIDR != normalizedCIDR
            {
                state.lastKnownNetworkIPv4CIDR = normalizedCIDR
                changed = true
            }
            if let suffix = try? MagicDNSSettings.normalizedDNSSuffix(magicDNSSuffix) {
                for index in state.services.indices {
                    guard let hostname = hostnamesByPeerID[state.services[index].targetPeerID],
                          let normalizedHostname = try? GatewayPublishedServicesValidator.normalizeLabel(
                              hostname,
                              field: "Target hostname"
                          )
                    else { continue }
                    if state.services[index].lastKnownTargetHostname != normalizedHostname {
                        state.services[index].lastKnownTargetHostname = normalizedHostname
                        changed = true
                    }
                    if state.services[index].lastKnownMagicDNSSuffix != suffix {
                        state.services[index].lastKnownMagicDNSSuffix = suffix
                        changed = true
                    }
                }
            }
            guard changed else { return }
            do {
                try await save(state)
                await reconcileWithoutLock()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func reconcile() async {
        await withMutation { await reconcileWithoutLock() }
    }

    func refreshStatus() async {
        await withMutation { await refreshStatusWithoutLock() }
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

    func setRetainsRuntimeAfterDisconnect(_ retainsRuntime: Bool) async {
        retainsRuntimeAfterDisconnect = retainsRuntime
        guard desiredEnabled else { return }
        do {
            try await client.setRetainsRuntimeAfterDisconnect(retainsRuntime)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopForLifecycle(retainRuntime: Bool = false) async {
        suspendConnectionRecovery()
        stopStatusPolling()
        if retainRuntime, desiredEnabled {
            await setRetainsRuntimeAfterDisconnect(true)
            return
        }
        await withMutation {
            guard desiredEnabled || status.state != .stopped else { return }
            await stopWithoutLock()
        }
    }

    func resumeAfterLifecycle() async {
        startConnectionRecovery()
        await setRetainsRuntimeAfterDisconnect(retainsRuntimeAfterDisconnect)
        await reconcile()
    }

    private func save(_ state: GatewayPersistedState) async throws {
        let state = try GatewayPublishedServicesValidator.validate(state)
        try await configurationStore.save(state)
        persistedState = state
    }

    private func reconcileWithoutLock() async {
        guard let state = persistedState, state.desiredEnabled else {
            if status.state != .stopped || lastAppliedConfiguration != nil {
                await stopWithoutLock()
            } else {
                status = .stopped
            }
            return
        }
        do {
            let configuration = try GatewayConfigurationFactory.makeRuntimeConfiguration(from: state)
            let shouldStart = lastAppliedConfiguration == nil || status.state == .stopped
            isBusy = true
            status.state = .starting
            defer { isBusy = false }
            if let helperRegistration { try await helperRegistration.ensureRegistered() }
            try await connectionMonitor?.probeHelperAvailability()
            try await client.setRetainsRuntimeAfterDisconnect(retainsRuntimeAfterDisconnect)
            if shouldStart {
                try await client.start(configuration: configuration)
            } else if lastAppliedConfiguration != configuration {
                try await client.apply(configuration: configuration)
            }
            lastAppliedConfiguration = configuration
            status = try await client.status()
            lastError = status.lastError
            startStatusPolling()
        } catch {
            status.state = .failed
            status.lastError = error.localizedDescription
            lastError = error.localizedDescription
        }
    }

    private func stopWithoutLock() async {
        isBusy = true
        status.state = .stopping
        stopStatusPolling()
        defer { isBusy = false }
        do {
            try await client.stop()
            status = .stopped
            lastAppliedConfiguration = nil
            lastError = nil
        } catch {
            status.state = .failed
            status.lastError = error.localizedDescription
            lastError = error.localizedDescription
        }
    }

    private func refreshStatusWithoutLock() async {
        guard desiredEnabled else { return }
        do {
            status = try await client.status()
            lastError = status.lastError
            if status.state == .stopped, recoveryEnabled {
                lastAppliedConfiguration = nil
                await reconcileWithoutLock()
            }
        } catch {
            status.state = .failed
            status.lastError = error.localizedDescription
            lastError = error.localizedDescription
        }
    }

    private func startStatusPolling() {
        guard statusTask == nil else { return }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let fast = self.status.certificates.contains { certificate in
                    certificate.state == .pending
                        || certificate.state == .issuing
                        || certificate.state == .renewing
                }
                do {
                    try await Task.sleep(for: fast ? .seconds(2) : .seconds(10))
                } catch {
                    return
                }
                await self.refreshStatus()
            }
        }
    }

    private func stopStatusPolling() {
        statusTask?.cancel()
        statusTask = nil
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
        lastAppliedConfiguration = nil
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
    func setRetainsRuntimeAfterDisconnect(_ retainsRuntime: Bool) async throws {}
}
