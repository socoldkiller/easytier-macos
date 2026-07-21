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
    private(set) var magicDNSState: MagicDNSOperationalState = .disabled
    private(set) var magicDNSStateByServiceID: [String: MagicDNSOperationalState] = [:]
    private(set) var servicesVisible = false
    private(set) var publishingNetworkName = "Unavailable"
    private(set) var appliedMagicDNSSuffix: String?
    private(set) var topologyMembers: [NetworkMemberStatus] = []
    private(set) var expectedIPv4ByServiceID: [String: String] = [:]

    var desiredEnabled: Bool { persistedState?.desiredEnabled == true }
    var services: [GatewayPublishedService] { persistedState?.services ?? [] }
    var publishingNetworkConfigID: String? { persistedState?.publishingNetworkConfigID }
    var acmeConfiguration: GatewayACMEConfiguration? { persistedState?.acmeAccount }
    var dnsCredentials: [GatewayDNSCredentialDescriptor] { persistedState?.dnsCredentials ?? [] }
    var isTLSConfigured: Bool {
        acmeConfiguration?.termsOfServiceAgreed == true
            && acmeConfiguration?.contactEmail?.isEmpty == false
    }

    func magicDNSState(for serviceID: String) -> MagicDNSOperationalState {
        magicDNSStateByServiceID[serviceID] ?? magicDNSState
    }

    @ObservationIgnored private let client: any GatewayClient
    @ObservationIgnored private let configurationStore: any GatewayConfigurationStoring
    @ObservationIgnored private let credentialStore: any GatewayCredentialStoring
    @ObservationIgnored let helperRegistration: HelperRegistrationService?
    @ObservationIgnored private let connectionMonitor: (any GatewayConnectionMonitoring)?
    @ObservationIgnored private let magicDNSResolver: any MagicDNSResolving
    @ObservationIgnored private weak var store: EasyTierAppStore?
    @ObservationIgnored private var environmentTask: Task<Void, Never>?
    @ObservationIgnored private var environmentGeneration: UInt64 = 0
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var activeStatusPollingInterval: Duration?
    @ObservationIgnored private var recoveryEnabled = false
    @ObservationIgnored private var retainsRuntimeAfterDisconnect = false
    @ObservationIgnored private var lastAppliedConfiguration: GatewayConfiguration?
    @ObservationIgnored private var lastAppliedCredentialRevisions: [String: UInt64] = [:]
    @ObservationIgnored private var mutationLocked = false
    @ObservationIgnored private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        client: any GatewayClient,
        configurationStore: any GatewayConfigurationStoring,
        credentialStore: any GatewayCredentialStoring = SystemGatewayCredentialStore(),
        helperRegistration: HelperRegistrationService?,
        connectionMonitor: (any GatewayConnectionMonitoring)? = nil,
        magicDNSResolver: any MagicDNSResolving = SystemMagicDNSResolver()
    ) {
        self.client = client
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
        self.helperRegistration = helperRegistration
        self.connectionMonitor = connectionMonitor
        self.magicDNSResolver = magicDNSResolver
    }

    func bind(to store: EasyTierAppStore) {
        self.store = store
        store.runtimeEnvironmentDidChange = { [weak self, weak store] in
            guard let self, let store else { return }
            self.environmentDidChange(store: store)
        }
        environmentDidChange(store: store)
    }

    func environmentDidChange(store: EasyTierAppStore) {
        environmentGeneration &+= 1
        let generation = environmentGeneration
        environmentTask?.cancel()
        environmentTask = Task { [weak self, weak store] in
            guard let self, let store else { return }
            await self.monitorEnvironment(store: store, generation: generation)
        }
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
        if let store { environmentDidChange(store: store) }
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
        targetInstanceID: String? = nil,
        targetHostname: String,
        magicDNSSuffix: String,
        serviceLabel: String,
        targetPort: Int
    ) async throws -> GatewayPublishedService {
        guard store == nil || magicDNSState == .ready else {
            throw GatewayConfigurationValidationError.invalid(
                "Wait for Magic DNS to become ready before publishing a service."
            )
        }
        let draft = try GatewayPublishedServicesValidator.makeDraft(
            networkConfigID: networkConfigID,
            targetPeerID: targetPeerID,
            targetInstanceID: targetInstanceID,
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
                contactEmail: contactEmail,
                termsOfServiceAgreed: termsOfServiceAgreed
            )
            try await save(state)
            if state.desiredEnabled {
                await reconcileWithoutLock()
                if status.state == .failed {
                    throw EasyTierCoreError.operationFailed(
                        lastError ?? "Gateway failed to apply the SSL settings."
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
                guard store == nil || magicDNSState != .disabled else {
                    throw GatewayConfigurationValidationError.invalid(
                        "Turn on Magic DNS before enabling this service."
                    )
                }
                guard let acme = state.acmeAccount, acme.termsOfServiceAgreed else {
                    throw GatewayConfigurationValidationError.invalid(
                        "Accept the certificate service terms before enabling this service."
                    )
                }
                guard acme.contactEmail != nil else {
                    throw GatewayConfigurationValidationError.invalid(
                        "Enter a certificate contact email before enabling this service."
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

    func updateCertificatePolicy(
        serviceID: String,
        policy: GatewayCertificatePolicy
    ) async throws {
        try await withMutation {
            guard var state = persistedState,
                  let index = state.services.firstIndex(where: { $0.id == serviceID })
            else {
                throw GatewayConfigurationValidationError.invalid("Published service was not found.")
            }
            state.services[index].certificatePolicy = policy
            try await save(state)
            await reconcileWithoutLock()
        }
    }

    func saveDNSCredential(
        descriptor: GatewayDNSCredentialDescriptor,
        secret: GatewayCredentialSecret
    ) async throws {
        try await withMutation {
            var state = persistedState ?? .empty
            var descriptor = descriptor
            if let index = state.dnsCredentials.firstIndex(where: { $0.id == descriptor.id }) {
                descriptor.revision = state.dnsCredentials[index].revision &+ 1
                state.dnsCredentials[index] = descriptor
            } else {
                state.dnsCredentials.append(descriptor)
            }
            try await credentialStore.save(secret, id: descriptor.id)
            try await save(state)
            await reconcileWithoutLock()
        }
    }

    func loadDNSCredentialSecret(id: String) async throws -> GatewayCredentialSecret? {
        try await credentialStore.load(id: id)
    }

    func deleteDNSCredential(id: String) async throws {
        try await withMutation {
            guard var state = persistedState else { return }
            let isReferenced = state.services.contains { service in
                switch service.certificatePolicy.challenge {
                case .http01: false
                case let .dns01(credentialID): credentialID == id
                }
            }
            guard !isReferenced else {
                throw GatewayConfigurationValidationError.invalid(
                    "Change services that use this DNS credential before deleting it."
                )
            }
            state.dnsCredentials.removeAll { $0.id == id }
            try await credentialStore.remove(id: id)
            try await save(state)
            await reconcileWithoutLock()
        }
    }

    func updateService(
        serviceID: String,
        targetPeerID: String,
        targetInstanceID: String? = nil,
        targetHostname: String,
        magicDNSSuffix: String,
        port: Int,
        certificatePolicy: GatewayCertificatePolicy? = nil
    ) async throws {
        try await withMutation {
            guard var state = persistedState,
                  let index = state.services.firstIndex(where: { $0.id == serviceID })
            else {
                throw GatewayConfigurationValidationError.invalid("Published service was not found.")
            }

            var updated = state.services[index]
            updated.targetPeerID = targetPeerID
            updated.targetInstanceID = targetInstanceID
            updated.lastKnownTargetHostname = targetHostname
            updated.lastKnownMagicDNSSuffix = magicDNSSuffix
            updated.targetPort = port
            if let certificatePolicy {
                updated.certificatePolicy = certificatePolicy
            }
            guard updated != state.services[index] else { return }

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
        guard let state = persistedState,
              state.desiredEnabled,
              (store == nil || magicDNSState != .disabled)
        else {
            if status.state != .stopped || lastAppliedConfiguration != nil {
                await stopWithoutLock()
            } else {
                status = .stopped
            }
            return
        }
        do {
            let availability = Self.upstreamAvailability(for: magicDNSState)
            let availabilityByServiceID = magicDNSStateByServiceID.mapValues(
                Self.upstreamAvailability(for:)
            )
            let configuration = try GatewayConfigurationFactory.makeRuntimeConfiguration(
                from: state,
                routeAvailability: availability,
                routeAvailabilityByServiceID: availabilityByServiceID,
                expectedIPv4ByServiceID: expectedIPv4ByServiceID
            )
            let shouldStart = lastAppliedConfiguration == nil || status.state == .stopped
            let configurationChanged = lastAppliedConfiguration != configuration
            let credentialRevisions = Dictionary(
                uniqueKeysWithValues: state.dnsCredentials.map { ($0.id, $0.revision) }
            )
            let credentialsChanged = credentialRevisions != lastAppliedCredentialRevisions
            if !shouldStart, !configurationChanged, !credentialsChanged, status.state == .running {
                startStatusPolling()
                return
            }
            let secrets = try await credentialStore.resolve(state.dnsCredentials)
            isBusy = true
            status.state = .starting
            defer { isBusy = false }
            if let helperRegistration { try await helperRegistration.ensureRegistered() }
            try await connectionMonitor?.probeHelperAvailability()
            try await client.setRetainsRuntimeAfterDisconnect(retainsRuntimeAfterDisconnect)
            if shouldStart {
                try await client.start(configuration: configuration, secrets: secrets)
            } else if configurationChanged || credentialsChanged {
                try await client.apply(configuration: configuration, secrets: secrets)
            }
            lastAppliedConfiguration = configuration
            lastAppliedCredentialRevisions = credentialRevisions
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
            lastAppliedCredentialRevisions = [:]
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
            } else {
                startStatusPolling()
            }
        } catch {
            status.state = .failed
            status.lastError = error.localizedDescription
            lastError = error.localizedDescription
        }
    }

    private func startStatusPolling() {
        let interval = Self.statusPollingInterval(for: status)
        guard statusTask == nil || activeStatusPollingInterval != interval else { return }
        statusTask?.cancel()
        activeStatusPollingInterval = interval
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = Self.statusPollingInterval(for: self.status)
                self.activeStatusPollingInterval = interval
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                await self.refreshStatus()
            }
        }
    }

    static func statusPollingInterval(for status: GatewayStatus) -> Duration {
        let routesAreConverging = status.routes.contains { route in
            route.resolutionState == .waiting || route.resolutionState == .resolving
        }
        if routesAreConverging { return .seconds(1) }

        let certificatesAreConverging = status.certificates.contains { certificate in
            certificate.state == .pending
                || certificate.state == .issuing
                || certificate.state == .renewing
        }
        return certificatesAreConverging ? .seconds(2) : .seconds(10)
    }

    private func stopStatusPolling() {
        statusTask?.cancel()
        statusTask = nil
        activeStatusPollingInterval = nil
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

    private func monitorEnvironment(store: EasyTierAppStore, generation: UInt64) async {
        while !Task.isCancelled, generation == environmentGeneration {
            let probe = environmentProbe(store: store)
            servicesVisible = probe.servicesVisible
            publishingNetworkName = probe.networkName
            topologyMembers = probe.members

            let states = await resolveMagicDNSStates(for: probe)
            guard !Task.isCancelled, generation == environmentGeneration else { return }
            let nextState = states.aggregate
            let nextStatesByServiceID = states.byServiceID
            expectedIPv4ByServiceID = states.expectedIPv4ByServiceID
            appliedMagicDNSSuffix = probe.appliedSuffix
                ?? (nextState == .ready ? probe.desiredSuffix : nil)

            magicDNSState = nextState
            magicDNSStateByServiceID = nextStatesByServiceID
            await reconcileTopologyFromEnvironment(
                probe,
                resolvedTargetsByServiceID: states.resolvedTargetsByServiceID
            )
            await reconcile()

            do {
                let isStable = nextState == .ready && status.state == .running
                try await Task.sleep(for: isStable ? .seconds(5) : .seconds(1))
            } catch {
                return
            }
        }
    }

    private struct EnvironmentProbe {
        var networkConfigID: String?
        var desiredMagicDNSEnabled: Bool
        var desiredSuffix: String
        var appliedMagicDNSEnabled: Bool?
        var servicesVisible: Bool
        var isTransitioning: Bool
        var networkName: String
        var allowedIPv4CIDR: String?
        var appliedSuffix: String?
        var localProbe: MagicDNSProbeTarget?
        var enabledServices: [GatewayPublishedService]
        var serviceHostnamesByID: [String: String]
        var identityMatchedMembersByServiceID: [String: NetworkMemberStatus]
        var liveMembers: [NetworkMemberStatus]
        var members: [NetworkMemberStatus]
    }

    private struct MagicDNSProbeTarget: Equatable, Sendable {
        var hostname: String
        var expectedIPv4: String
    }

    private struct ResolvedMagicDNSStates: Sendable {
        var aggregate: MagicDNSOperationalState
        var byServiceID: [String: MagicDNSOperationalState]
        var expectedIPv4ByServiceID: [String: String]
        var resolvedTargetsByServiceID: [String: ResolvedGatewayServiceTarget]
    }

    private func environmentProbe(store: EasyTierAppStore) -> EnvironmentProbe {
        let configID = publishingNetworkConfigID ?? store.selectedConfig?.instance_id
        let config = configID.flatMap { id in store.configs.first { $0.instance_id == id } }
        let desiredEnabled = config?.enable_magic_dns == true
        let desiredSuffix = store.magicDNSSettings.dnsSuffix
        let servicesVisible = config.map { $0.enable_magic_dns == true }
            ?? (publishingNetworkConfigID != nil && !services.isEmpty)
        let transition = configID.flatMap { store.runtimeTransitionsByConfigID[$0] }
        let instance = config.flatMap { store.runningInstance(matching: $0) }
        let detail = instance.flatMap { store.runtimeDetails[$0.name] ?? $0.detail }
        let members = configID == store.selectedConfig?.instance_id
            ? store.selectedStatusSnapshot.members
            : detail?.memberStatuses ?? []
        let appliedSuffix = detail?.applied_magic_dns_enabled == true
            ? detail?.applied_magic_dns_suffix
            : nil
        let runtimeHostname = detail?.my_node_info?.hostname?.nilIfEmpty
            ?? config?.hostname?.nilIfEmpty
        let runtimeCIDR = detail?.my_node_info?.virtual_ipv4?.displayString.nilIfEmpty
        let configuredCIDR = config?.virtual_ipv4.nilIfEmpty.map { address in
            address.contains("/") ? address : "\(address)/\(config?.network_length ?? 24)"
        }
        let localCIDR = runtimeCIDR ?? configuredCIDR
        let localIPv4 = localCIDR?.split(separator: "/", maxSplits: 1).first.map(String.init)
        let localProbe = runtimeHostname.flatMap { hostname in
            localIPv4.map { expectedIPv4 in
                MagicDNSProbeTarget(
                    hostname: Self.magicDNSHostname(label: hostname, suffix: desiredSuffix),
                    expectedIPv4: expectedIPv4
                )
            }
        }
        let liveMembers = members.filter { member in
            member.isLive && member.copyableIPv4Address != nil
        }
        let enabledServices = services.filter(\.desiredEnabled)
        var serviceHostnamesByID: [String: String] = [:]
        var identityMatchedMembersByServiceID: [String: NetworkMemberStatus] = [:]
        for service in enabledServices {
            let matchedMember = Self.identityMatchedMember(for: service, members: liveMembers)
            if let matchedMember {
                identityMatchedMembersByServiceID[service.id] = matchedMember
            }
            serviceHostnamesByID[service.id] = Self.magicDNSHostname(
                label: matchedMember?.hostname ?? service.lastKnownTargetHostname,
                suffix: desiredSuffix
            )
        }
        return EnvironmentProbe(
            networkConfigID: configID,
            desiredMagicDNSEnabled: desiredEnabled,
            desiredSuffix: desiredSuffix,
            appliedMagicDNSEnabled: detail?.applied_magic_dns_enabled,
            servicesVisible: servicesVisible,
            isTransitioning: transition != nil,
            networkName: config?.network_name ?? "Unavailable",
            allowedIPv4CIDR: localCIDR,
            appliedSuffix: appliedSuffix,
            localProbe: localProbe,
            enabledServices: enabledServices,
            serviceHostnamesByID: serviceHostnamesByID,
            identityMatchedMembersByServiceID: identityMatchedMembersByServiceID,
            liveMembers: liveMembers,
            members: members
        )
    }

    private func reconcileTopologyFromEnvironment(
        _ probe: EnvironmentProbe,
        resolvedTargetsByServiceID: [String: ResolvedGatewayServiceTarget]
    ) async {
        guard let networkConfigID = probe.networkConfigID,
              probe.desiredMagicDNSEnabled
        else { return }
        await withMutation {
            guard var state = persistedState,
                  state.publishingNetworkConfigID == networkConfigID
            else { return }

            var changed = false
            if let allowedIPv4CIDR = probe.allowedIPv4CIDR,
               let normalizedCIDR = try? GatewayPublishedServicesValidator.normalizeIPv4CIDR(
                   allowedIPv4CIDR
               ),
               state.lastKnownNetworkIPv4CIDR != normalizedCIDR
            {
                state.lastKnownNetworkIPv4CIDR = normalizedCIDR
                changed = true
            }

            let suffix = try? MagicDNSSettings.normalizedDNSSuffix(
                probe.appliedSuffix ?? probe.desiredSuffix
            )
            for index in state.services.indices {
                guard let target = resolvedTargetsByServiceID[state.services[index].id] else {
                    continue
                }
                if state.services[index].targetPeerID != target.member.peerID {
                    state.services[index].targetPeerID = target.member.peerID
                    changed = true
                }
                if state.services[index].targetInstanceID != target.member.instanceID {
                    state.services[index].targetInstanceID = target.member.instanceID
                    changed = true
                }
                if let normalizedHostname = try? GatewayPublishedServicesValidator.normalizeLabel(
                    target.member.hostname,
                    field: "Target hostname"
                ), state.services[index].lastKnownTargetHostname != normalizedHostname {
                    state.services[index].lastKnownTargetHostname = normalizedHostname
                    changed = true
                }
                if let suffix, state.services[index].lastKnownMagicDNSSuffix != suffix {
                    state.services[index].lastKnownMagicDNSSuffix = suffix
                    changed = true
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

    private func resolveMagicDNSStates(
        for probe: EnvironmentProbe
    ) async -> ResolvedMagicDNSStates {
        let fallbackByServiceID = Dictionary(
            uniqueKeysWithValues: probe.enabledServices.map { ($0.id, MagicDNSOperationalState.loading) }
        )
        guard probe.desiredMagicDNSEnabled else {
            return ResolvedMagicDNSStates(
                aggregate: .disabled,
                byServiceID: fallbackByServiceID.mapValues { _ in .disabled },
                expectedIPv4ByServiceID: [:],
                resolvedTargetsByServiceID: [:]
            )
        }
        guard !probe.isTransitioning,
              probe.appliedMagicDNSEnabled != false,
              probe.appliedSuffix == nil || probe.appliedSuffix == probe.desiredSuffix
        else {
            return ResolvedMagicDNSStates(
                aggregate: .loading,
                byServiceID: fallbackByServiceID,
                expectedIPv4ByServiceID: [:],
                resolvedTargetsByServiceID: [:]
            )
        }

        let serviceHostnames = probe.enabledServices.compactMap {
            probe.serviceHostnamesByID[$0.id]
        }
        let hostnames = Set(serviceHostnames + [probe.localProbe?.hostname].compactMap(\.self))
        let resolvedByHostname = await resolveIPv4(hostnames: hostnames)

        if !probe.enabledServices.isEmpty {
            var byServiceID: [String: MagicDNSOperationalState] = [:]
            var expectedIPv4ByServiceID: [String: String] = [:]
            var resolvedTargetsByServiceID: [String: ResolvedGatewayServiceTarget] = [:]
            for service in probe.enabledServices {
                guard let hostname = probe.serviceHostnamesByID[service.id] else {
                    byServiceID[service.id] = .loading
                    continue
                }
                let resolved = resolvedByHostname[hostname] ?? []
                let identityMatchedMember = probe.identityMatchedMembersByServiceID[service.id]
                let member = identityMatchedMember
                    ?? Self.uniqueLegacyMember(for: service, members: probe.liveMembers)
                guard let member, let expectedIPv4 = member.copyableIPv4Address else {
                    byServiceID[service.id] = .loading
                    continue
                }

                let state = Self.magicDNSState(
                    target: MagicDNSProbeTarget(hostname: hostname, expectedIPv4: expectedIPv4),
                    resolved: resolved
                )
                byServiceID[service.id] = state
                expectedIPv4ByServiceID[service.id] = expectedIPv4
                if identityMatchedMember != nil || state == .ready {
                    resolvedTargetsByServiceID[service.id] = ResolvedGatewayServiceTarget(
                        member: member
                    )
                }
            }
            return ResolvedMagicDNSStates(
                aggregate: Self.aggregateMagicDNSState(byServiceID),
                byServiceID: byServiceID,
                expectedIPv4ByServiceID: expectedIPv4ByServiceID,
                resolvedTargetsByServiceID: resolvedTargetsByServiceID
            )
        }

        guard let localProbe = probe.localProbe else {
            return ResolvedMagicDNSStates(
                aggregate: .loading,
                byServiceID: [:],
                expectedIPv4ByServiceID: [:],
                resolvedTargetsByServiceID: [:]
            )
        }
        return ResolvedMagicDNSStates(
            aggregate: Self.magicDNSState(
                target: localProbe,
                resolved: resolvedByHostname[localProbe.hostname] ?? []
            ),
            byServiceID: [:],
            expectedIPv4ByServiceID: [:],
            resolvedTargetsByServiceID: [:]
        )
    }

    private func resolveIPv4(hostnames: Set<String>) async -> [String: Set<String>] {
        let resolver = magicDNSResolver
        return await withTaskGroup(of: (String, Set<String>).self) { group in
            for hostname in hostnames {
                group.addTask {
                    (hostname, await resolver.resolveIPv4(hostname: hostname))
                }
            }
            var resolvedByHostname: [String: Set<String>] = [:]
            for await (hostname, addresses) in group {
                resolvedByHostname[hostname] = addresses
            }
            return resolvedByHostname
        }
    }

    private static func magicDNSState(
        target: MagicDNSProbeTarget,
        resolved: Set<String>
    ) -> MagicDNSOperationalState {
        if resolved.isEmpty { return .loading }
        if resolved == [target.expectedIPv4] { return .ready }
        return .mismatch(expected: target.expectedIPv4, resolved: resolved)
    }

    private static func identityMatchedMember(
        for service: GatewayPublishedService,
        members: [NetworkMemberStatus]
    ) -> NetworkMemberStatus? {
        if let targetInstanceID = service.targetInstanceID {
            return members.first { $0.instanceID == targetInstanceID }
        }
        return members.first { $0.peerID == service.targetPeerID }
    }

    private static func uniqueLegacyMember(
        for service: GatewayPublishedService,
        members: [NetworkMemberStatus]
    ) -> NetworkMemberStatus? {
        guard service.targetInstanceID == nil,
              let targetHostname = try? GatewayPublishedServicesValidator.normalizeLabel(
                  service.lastKnownTargetHostname,
                  field: "Target hostname"
              )
        else { return nil }
        let candidates = members.filter { member in
            guard let hostname = try? GatewayPublishedServicesValidator.normalizeLabel(
                member.hostname,
                field: "Target hostname"
            ) else { return false }
            return hostname == targetHostname
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func aggregateMagicDNSState(
        _ statesByServiceID: [String: MagicDNSOperationalState]
    ) -> MagicDNSOperationalState {
        for serviceID in statesByServiceID.keys.sorted() {
            if case let .mismatch(expected, resolved) = statesByServiceID[serviceID] {
                return .mismatch(expected: expected, resolved: resolved)
            }
        }
        if statesByServiceID.values.contains(.loading) { return .loading }
        return statesByServiceID.isEmpty ? .loading : .ready
    }

    private static func magicDNSHostname(label: String, suffix: String) -> String {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return "\(label).\(suffix)"
    }

    private static func upstreamAvailability(
        for state: MagicDNSOperationalState
    ) -> GatewayUpstreamAvailability {
        switch state {
        case .ready: .ready
        case .mismatch: .unavailable
        case .loading, .disabled: .waiting
        }
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
