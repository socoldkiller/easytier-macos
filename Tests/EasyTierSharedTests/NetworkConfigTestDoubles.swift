import Foundation
import ServiceManagement
import Testing
@testable import EasyTierShared

func hostnameIntent(instanceID: String, networkName: String, base: String, desired: String) -> RuntimeIntent {
    RuntimeIntent(
        target: RuntimeIntentTarget(
            networkName: networkName,
            instanceID: instanceID,
            recentHostname: base,
            isLocal: true
        ),
        desiredHostname: desired,
        baseHostname: base,
        status: .pending
    )
}

func networkConfigRPCRequestPayloadObject(_ payload: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
        throw EasyTierCoreError.invalidResponse("RPC payload is not a JSON object")
    }
    return object
}

final class MemoryNetworkSecretStore: NetworkSecretStore, @unchecked Sendable {
    var secrets: [String: String]
    var deletedIDs: [String] = []
    var savePurposes: [NetworkSecretAccessPurpose] = []
    var readPurposes: [NetworkSecretAccessPurpose] = []
    var deletePurposes: [NetworkSecretAccessPurpose] = []
    var readReasons: [String?] = []
    var readError: Error?
    var saveError: Error?
    var deleteError: Error?
    var containsError: Error?
    var authenticationPurposes: [NetworkSecretAccessPurpose] = []
    private(set) var presenceCallCount = 0
    private(set) var authenticationInvalidationCount = 0

    init(secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    func save(
        _ secret: String,
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose
    ) async throws {
        savePurposes.append(purpose)
        if let saveError { throw saveError }
        secrets[config.network_name] = secret
    }

    func secret(
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose,
        reason: String?
    ) async throws -> String? {
        readPurposes.append(purpose)
        readReasons.append(reason)
        if let readError { throw readError }
        return secrets[config.network_name]
    }

    func deleteSecret(
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose
    ) async throws {
        deletePurposes.append(purpose)
        if let deleteError { throw deleteError }
        deletedIDs.append(config.network_name)
        secrets.removeValue(forKey: config.network_name)
    }

    func presence(for config: NetworkConfig) async throws -> NetworkSecretPresence {
        presenceCallCount += 1
        if let containsError { throw containsError }
        return secrets[config.network_name] == nil ? .missing : .present
    }

    func authenticate(
        for _: NetworkConfig,
        purpose: NetworkSecretAccessPurpose
    ) async throws {
        authenticationPurposes.append(purpose)
    }

    func invalidateAuthenticationSession() {
        authenticationInvalidationCount += 1
    }
}

final class BlockingNetworkSecretStore: NetworkSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private let storedSecret: String
    private var storedReadCount = 0
    private var storedDeleteCount = 0
    private var storedAuthenticationInvalidationCount = 0
    private var readContinuations: [CheckedContinuation<Void, Never>] = []
    private var deleteContinuations: [CheckedContinuation<Void, Never>] = []

    init(secret: String) {
        storedSecret = secret
    }

    var readCount: Int {
        lock.withLock { storedReadCount }
    }

    var authenticationInvalidationCount: Int {
        lock.withLock { storedAuthenticationInvalidationCount }
    }

    var deleteCount: Int {
        lock.withLock { storedDeleteCount }
    }

    func save(
        _: String,
        for _: NetworkConfig,
        purpose _: NetworkSecretAccessPurpose
    ) async throws {}

    func secret(
        for _: NetworkConfig,
        purpose _: NetworkSecretAccessPurpose,
        reason _: String?
    ) async throws -> String? {
        await withCheckedContinuation { continuation in
            lock.withLock {
                storedReadCount += 1
                readContinuations.append(continuation)
            }
        }
        return storedSecret
    }

    func deleteSecret(
        for _: NetworkConfig,
        purpose _: NetworkSecretAccessPurpose
    ) async throws {
        await withCheckedContinuation { continuation in
            lock.withLock {
                storedDeleteCount += 1
                deleteContinuations.append(continuation)
            }
        }
    }

    func presence(for _: NetworkConfig) async throws -> NetworkSecretPresence { .present }

    func invalidateAuthenticationSession() {
        lock.withLock { storedAuthenticationInvalidationCount += 1 }
    }

    func releaseReads() {
        let continuations = lock.withLock {
            let continuations = readContinuations
            readContinuations.removeAll()
            return continuations
        }
        continuations.forEach { $0.resume() }
    }

    func releaseDeletes() {
        let continuations = lock.withLock {
            let continuations = deleteContinuations
            deleteContinuations.removeAll()
            return continuations
        }
        continuations.forEach { $0.resume() }
    }
}

final class PendingStartClient: EasyTierCoreClient, @unchecked Sendable {
    var didRun = false

    func validate(toml _: String) async throws {}

    func run(toml _: String) async throws {
        didRun = true
    }

    func stop(instanceNames _: [String]) async throws {}
    func retain(instanceNames _: [String]) async throws {}
    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] { [:] }
    func configureRPCPortal(_ rpcPortal: String?, whitelist _: [String]?) async throws {
        if rpcPortal != nil { throw EasyTierCoreError.operationFailed("unsupported") }
    }

    func callJSONRPC(
        clientID _: String,
        url _: URL,
        service _: String,
        method _: String,
        domain _: String?,
        payload _: String
    ) async throws -> String {
        throw EasyTierCoreError.operationFailed("unsupported")
    }
}

final class RecordingToggleClient: EasyTierCoreClient, EasyTierHelperShutdownClient, @unchecked Sendable {
    var runConfigs: [NetworkConfig] = []
    var runTOMLs: [String] = []
    var stoppedInstanceNames: [[String]] = []
    var retainedInstanceNames: [[String]] = []
    var networkInfos: [String: NetworkInstanceRunningInfo] = [:]
    var configuredRPCPortals: [String?] = []
    var configuredRPCPortalWhitelists: [[String]?] = []
    var jsonRPCCalls: [EasyTierRPCRequest] = []
    var jsonRPCResponsesByMethod: [String: String] = [:]
    var shutdownCount = 0
    var runError: Error?
    var stopError: Error?
    var collectError: Error?
    var jsonRPCError: Error?
    var collectCount = 0

    func validate(toml _: String) async throws {}

    func run(toml: String) async throws {
        runTOMLs.append(toml)
        if let config = try? NetworkConfigTOMLCodec.decode(toml) {
            runConfigs.append(config)
        }
        if let runError { throw runError }
    }

    func stop(instanceNames: [String]) async throws {
        stoppedInstanceNames.append(instanceNames)
        if let stopError { throw stopError }
    }

    func retain(instanceNames: [String]) async throws {
        retainedInstanceNames.append(instanceNames)
    }

    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] {
        collectCount += 1
        if let collectError { throw collectError }
        return networkInfos
    }
    func configureRPCPortal(_ rpcPortal: String?, whitelist: [String]?) async throws {
        configuredRPCPortals.append(rpcPortal)
        configuredRPCPortalWhitelists.append(whitelist)
    }

    func callJSONRPC(
        clientID _: String,
        url _: URL,
        service: String,
        method: String,
        domain: String?,
        payload: String
    ) async throws -> String {
        jsonRPCCalls.append(EasyTierRPCRequest(service: service, method: method, domain: domain, payload: payload))
        if let jsonRPCError { throw jsonRPCError }
        return jsonRPCResponsesByMethod[method] ?? #"{"ok":true}"#
    }

    func shutdownHelper() async throws {
        shutdownCount += 1
    }
}

actor ControlledRuntimeRefreshClient: EasyTierCoreClient {
    private var collectContinuations: [
        Int: CheckedContinuation<[String: NetworkInstanceRunningInfo], Error>
    ] = [:]
    private var nextRequestID = 0
    private var stopErrorMessage: String?
    private var runCount = 0
    private var stopCount = 0

    func validate(toml _: String) async throws {}
    func run(toml _: String) async throws {
        runCount += 1
    }

    func stop(instanceNames _: [String]) async throws {
        stopCount += 1
        if let stopErrorMessage { throw EasyTierCoreError.operationFailed(stopErrorMessage) }
    }

    func retain(instanceNames _: [String]) async throws {}

    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] {
        let requestID = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            collectContinuations[requestID] = continuation
        }
    }

    func configureRPCPortal(_: String?, whitelist _: [String]?) async throws {}

    func callJSONRPC(
        clientID _: String,
        url _: URL,
        service _: String,
        method _: String,
        domain _: String?,
        payload _: String
    ) async throws -> String {
        throw EasyTierCoreError.operationFailed("unsupported")
    }

    func waitForRequest(_ requestID: Int) async {
        while collectContinuations[requestID] == nil {
            await Task.yield()
        }
    }

    func resolveRequest(
        _ requestID: Int,
        with infos: [String: NetworkInstanceRunningInfo]
    ) {
        collectContinuations.removeValue(forKey: requestID)?.resume(returning: infos)
    }

    func setStopErrorMessage(_ message: String?) {
        stopErrorMessage = message
    }

    func operationCounts() -> (runs: Int, stops: Int) {
        (runCount, stopCount)
    }
}

actor BlockingRuntimeMutationClient: EasyTierCoreClient {
    private let blocksRun: Bool
    private let blocksStop: Bool
    private var networkInfos: [String: NetworkInstanceRunningInfo]
    private var runContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuation: CheckedContinuation<Void, Error>?
    private var runCount = 0
    private var stopCount = 0
    private var retainCalls: [[String]] = []
    private var collectCount = 0

    init(
        blocksRun: Bool = false,
        blocksStop: Bool = false,
        networkInfos: [String: NetworkInstanceRunningInfo] = [:]
    ) {
        self.blocksRun = blocksRun
        self.blocksStop = blocksStop
        self.networkInfos = networkInfos
    }

    func validate(toml _: String) async throws {}

    func run(toml _: String) async throws {
        runCount += 1
        guard blocksRun else { return }
        try await withCheckedThrowingContinuation { continuation in
            runContinuation = continuation
        }
    }

    func stop(instanceNames _: [String]) async throws {
        stopCount += 1
        guard blocksStop else { return }
        try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func retain(instanceNames: [String]) async throws {
        retainCalls.append(instanceNames)
    }

    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] {
        collectCount += 1
        return networkInfos
    }

    func configureRPCPortal(_: String?, whitelist _: [String]?) async throws {}

    func callJSONRPC(
        clientID _: String,
        url _: URL,
        service _: String,
        method _: String,
        domain _: String?,
        payload _: String
    ) async throws -> String {
        throw EasyTierCoreError.operationFailed("unsupported")
    }

    func waitForRunRequest() async {
        while runContinuation == nil {
            await Task.yield()
        }
    }

    func waitForStopRequest() async {
        while stopContinuation == nil {
            await Task.yield()
        }
    }

    func resumeRun() {
        runContinuation?.resume()
        runContinuation = nil
    }

    func failStop(message: String) {
        stopContinuation?.resume(throwing: EasyTierCoreError.operationFailed(message))
        stopContinuation = nil
    }

    func resumeStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func setNetworkInfos(_ infos: [String: NetworkInstanceRunningInfo]) {
        networkInfos = infos
    }

    func counts() -> (runs: Int, stops: Int, retains: Int, collects: Int) {
        (runCount, stopCount, retainCalls.count, collectCount)
    }
}

final class RecordingSystemSleepPreventer: SystemSleepPreventing, @unchecked Sendable {
    private(set) var calls: [(prevented: Bool, reason: String)] = []
    private(set) var isPreventingSystemSleep = false

    func setSystemSleepPrevented(_ prevented: Bool, reason: String) {
        guard isPreventingSystemSleep != prevented else { return }
        isPreventingSystemSleep = prevented
        calls.append((prevented, reason))
    }
}

@MainActor
final class HelperRegistrationBackendSpy {
    var status: SMAppService.Status
    var statusAfterRegister: SMAppService.Status?
    var registerCount = 0
    var unregisterCount = 0
    var waitAfterUnregisterCount = 0
    var probeCount = 0
    var probeError: Error?
    var probeErrors: [Error] = []

    init(status: SMAppService.Status) {
        self.status = status
    }

    func backend() -> HelperRegistrationService.Backend {
        HelperRegistrationService.Backend(
            status: {
                if self.registerCount > 0, let statusAfterRegister = self.statusAfterRegister {
                    return statusAfterRegister
                }
                return self.status
            },
            register: {
                self.registerCount += 1
                if let statusAfterRegister = self.statusAfterRegister {
                    self.status = statusAfterRegister
                }
            },
            unregister: { self.unregisterCount += 1 },
            waitAfterUnregister: { self.waitAfterUnregisterCount += 1 },
            canInstallHelper: { true },
            probeHelper: {
                self.probeCount += 1
                if !self.probeErrors.isEmpty {
                    throw self.probeErrors.removeFirst()
                }
                if let probeError = self.probeError {
                    throw probeError
                }
            }
        )
    }
}

final class HelperRunErrorClient: EasyTierCoreClient, @unchecked Sendable {
    let payload: PrivilegedHelperErrorPayload

    init(payload: PrivilegedHelperErrorPayload) {
        self.payload = payload
    }

    func validate(toml _: String) async throws {}

    func run(toml _: String) async throws {
        throw PrivilegedHelperError.helperReported(payload)
    }

    func stop(instanceNames _: [String]) async throws {}
    func retain(instanceNames _: [String]) async throws {}
    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] { [:] }
    func configureRPCPortal(_: String?, whitelist _: [String]?) async throws {}
    func callJSONRPC(
        clientID _: String,
        url _: URL,
        service _: String,
        method _: String,
        domain _: String?,
        payload _: String
    ) async throws -> String { "" }
}
