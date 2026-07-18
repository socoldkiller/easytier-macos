import Darwin
import EasyTierShared
import Foundation

package protocol GatewayLeaseCancellation: Sendable {
    func cancel()
}

package protocol GatewayLeaseScheduling: Sendable {
    func schedule(
        after delay: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) -> any GatewayLeaseCancellation
}

package struct DispatchGatewayLeaseScheduler: GatewayLeaseScheduling, Sendable {
    package init() {}

    package func schedule(
        after delay: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) -> any GatewayLeaseCancellation {
        let workItem = DispatchWorkItem(block: operation)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
        return DispatchGatewayLeaseCancellation(workItem: workItem)
    }
}

private final class DispatchGatewayLeaseCancellation: GatewayLeaseCancellation, @unchecked Sendable {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

package struct GatewayHelperSession: Hashable, Sendable {
    package var id: UUID
    package var userID: uid_t

    package init(id: UUID = UUID(), userID: uid_t) {
        self.id = id
        self.userID = userID
    }
}

package enum GatewayHelperControllerError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case ownedByAnotherUser(uid_t)
    case notRunning
    case unknownCertificate(String)
    case restartFailed(newConfiguration: String, rollback: String)

    package var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            message
        case let .ownedByAnotherUser(userID):
            "Gateway is already owned by GUI user \(userID)."
        case .notRunning:
            "Gateway is not running."
        case let .unknownCertificate(certificateID):
            "Gateway certificate \(certificateID) does not exist."
        case let .restartFailed(newConfiguration, rollback):
            "Gateway restart failed: \(newConfiguration) Rollback: \(rollback)"
        }
    }
}

/// All mutable state and every process-global Gateway FFI call are confined to `queue`.
/// Remove `@unchecked Sendable` once the Objective-C XPC boundary can use a checked
/// serial executor without an adapter escape hatch.
package final class GatewayHelperController: @unchecked Sendable {
    package static let productionHTTPListener = "0.0.0.0:80"
    package static let productionHTTPSListener = "0.0.0.0:443"

    private let queue = DispatchQueue(label: "com.coldkiller.gateway.helper.runtime")
    private let ffi: any GatewayFFIRuntimeClient
    private let storageRoot: URL
    private let legacyStorageRoot: URL?
    private let httpListener: String
    private let httpsListener: String
    private let leaseDuration: TimeInterval
    private let leaseScheduler: any GatewayLeaseScheduling
    private let hasNetworkInstances: @Sendable () -> Bool
    private let idleExitHandler: @Sendable () -> Void

    private var ownerUserID: uid_t?
    private var attachedSessionIDs = Set<UUID>()
    private var currentConfiguration: GatewayConfiguration?
    private var currentFFIConfiguration: GatewayFFIConfiguration?
    private var leaseGeneration: UInt64 = 0
    private var leaseCancellation: (any GatewayLeaseCancellation)?

    package init(
        ffi: any GatewayFFIRuntimeClient = StaticGatewayFFIClient(),
        storageRoot: URL = URL(
            fileURLWithPath: "/Library/Application Support/Coldkiller/Gateway",
            isDirectory: true
        ),
        legacyStorageRoot: URL? = nil,
        httpListener: String = GatewayHelperController.productionHTTPListener,
        httpsListener: String = GatewayHelperController.productionHTTPSListener,
        leaseDuration: TimeInterval = 10,
        leaseScheduler: any GatewayLeaseScheduling = DispatchGatewayLeaseScheduler(),
        hasNetworkInstances: @escaping @Sendable () -> Bool = { false },
        idleExitHandler: @escaping @Sendable () -> Void = {}
    ) {
        self.ffi = ffi
        self.storageRoot = storageRoot
        self.legacyStorageRoot = legacyStorageRoot
        self.httpListener = httpListener
        self.httpsListener = httpsListener
        self.leaseDuration = leaseDuration
        self.leaseScheduler = leaseScheduler
        self.hasNetworkInstances = hasNetworkInstances
        self.idleExitHandler = idleExitHandler
    }

    package func start(configurationJSON: String, session: GatewayHelperSession) async throws {
        try await perform { [self] in
            let configuration = try decodeAndValidate(configurationJSON)
            try attach(session, claimingOwnership: true)
            let ffiConfiguration: GatewayFFIConfiguration
            do {
                ffiConfiguration = try makeFFIConfiguration(
                    configuration,
                    userID: session.userID
                )
            } catch {
                if currentConfiguration == nil {
                    clearRuntimeState()
                }
                throw error
            }

            do {
                try reconcileStart(
                    configuration: configuration,
                    ffiConfiguration: ffiConfiguration
                )
            } catch {
                if currentConfiguration == nil {
                    releaseOwnershipIfStopped()
                }
                throw error
            }
        }
    }

    package func apply(configurationJSON: String, session: GatewayHelperSession) async throws {
        try await perform { [self] in
            guard currentConfiguration != nil else {
                throw GatewayHelperControllerError.notRunning
            }
            let configuration = try decodeAndValidate(configurationJSON)
            try attach(session, claimingOwnership: false)
            let ffiConfiguration = try makeFFIConfiguration(configuration, userID: session.userID)
            try applyOrRestart(
                configuration: configuration,
                ffiConfiguration: ffiConfiguration
            )
        }
    }

    package func stop(session: GatewayHelperSession) async throws {
        try await perform { [self] in
            try attach(session, claimingOwnership: false, allowUnowned: true)
            try stopAndClearOwnership()
        }
    }

    package func status(session: GatewayHelperSession) async throws -> String {
        try await perform { [self] in
            try attach(session, claimingOwnership: false, allowUnowned: true)
            let status = try ffi.statusSync()
            if status.state == .stopped {
                clearRuntimeState()
            }
            return try encode(status)
        }
    }

    package func requestRenewal(
        certificateID: String?,
        session: GatewayHelperSession
    ) async throws {
        try await perform { [self] in
            guard let currentConfiguration else {
                throw GatewayHelperControllerError.notRunning
            }
            try attach(session, claimingOwnership: false)
            if let certificateID,
               !certificateID.isEmpty,
               !currentConfiguration.certificates.contains(where: { $0.id == certificateID })
            {
                throw GatewayHelperControllerError.unknownCertificate(certificateID)
            }
            try ffi.requestRenewalSync(certificateID: certificateID)
        }
    }

    package func sessionDidInvalidate(_ session: GatewayHelperSession) async {
        try? await perform { [self] in
            handleSessionInvalidation(session)
        }
    }

    package func shutdown() async throws {
        try await perform { [self] in
            cancelLeaseStop()
            defer { clearRuntimeState() }
            try ffi.stopSync()
        }
    }

    private func perform<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                dispatchPrecondition(condition: .onQueue(self.queue))
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func decodeAndValidate(_ json: String) throws -> GatewayConfiguration {
        dispatchPrecondition(condition: .onQueue(queue))
        do {
            let configuration = try JSONDecoder().decode(
                GatewayConfiguration.self,
                from: Data(json.utf8)
            )
            return try GatewayConfigurationValidator.validate(configuration)
        } catch {
            throw GatewayHelperControllerError.invalidConfiguration(error.localizedDescription)
        }
    }

    private func makeFFIConfiguration(
        _ configuration: GatewayConfiguration,
        userID: uid_t
    ) throws -> GatewayFFIConfiguration {
        dispatchPrecondition(condition: .onQueue(queue))
        let runtimeDirectory = storageRoot
            .appendingPathComponent(String(userID), isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
        try prepareStorageDirectory(runtimeDirectory)
        return GatewayFFIConfiguration(
            configuration: configuration,
            storageDirectory: runtimeDirectory.path,
            httpListener: httpListener,
            httpsListener: httpsListener
        )
    }

    private func prepareStorageDirectory(_ runtimeDirectory: URL) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let userDirectory = runtimeDirectory.deletingLastPathComponent()
        try migrateLegacyStorageIfNeeded()
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try setPermissions(0o755, at: storageRoot)
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        try setPermissions(0o700, at: userDirectory)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        try setPermissions(0o700, at: runtimeDirectory)
    }

    private func migrateLegacyStorageIfNeeded() throws {
        guard let legacyStorageRoot,
              legacyStorageRoot.standardizedFileURL != storageRoot.standardizedFileURL,
              FileManager.default.fileExists(atPath: legacyStorageRoot.path),
              !FileManager.default.fileExists(atPath: storageRoot.path)
        else { return }

        try FileManager.default.createDirectory(
            at: storageRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: legacyStorageRoot, to: storageRoot)
    }

    private func reconcileStart(
        configuration: GatewayConfiguration,
        ffiConfiguration: GatewayFFIConfiguration
    ) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let currentConfiguration else {
            try ffi.startSync(configuration: ffiConfiguration)
            self.currentConfiguration = configuration
            currentFFIConfiguration = ffiConfiguration
            return
        }
        guard currentConfiguration != configuration else { return }
        try applyOrRestart(configuration: configuration, ffiConfiguration: ffiConfiguration)
    }

    private func applyOrRestart(
        configuration: GatewayConfiguration,
        ffiConfiguration: GatewayFFIConfiguration
    ) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let previousConfiguration = currentConfiguration,
              let previousFFIConfiguration = currentFFIConfiguration
        else {
            throw GatewayHelperControllerError.notRunning
        }
        guard previousConfiguration != configuration else { return }

        if previousConfiguration.acme.directory == configuration.acme.directory {
            try ffi.applySync(configuration: ffiConfiguration)
            currentConfiguration = configuration
            currentFFIConfiguration = ffiConfiguration
            return
        }

        try ffi.stopSync()
        do {
            try ffi.startSync(configuration: ffiConfiguration)
            currentConfiguration = configuration
            currentFFIConfiguration = ffiConfiguration
        } catch {
            let newConfigurationError = error.localizedDescription
            do {
                try ffi.startSync(configuration: previousFFIConfiguration)
                currentConfiguration = previousConfiguration
                currentFFIConfiguration = previousFFIConfiguration
                throw GatewayHelperControllerError.restartFailed(
                    newConfiguration: newConfigurationError,
                    rollback: "Previous configuration was restored."
                )
            } catch let rollbackError as GatewayHelperControllerError {
                throw rollbackError
            } catch {
                clearRuntimeState()
                throw GatewayHelperControllerError.restartFailed(
                    newConfiguration: newConfigurationError,
                    rollback: "Previous configuration also failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func attach(
        _ session: GatewayHelperSession,
        claimingOwnership: Bool,
        allowUnowned: Bool = false
    ) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        if let ownerUserID, ownerUserID != session.userID {
            throw GatewayHelperControllerError.ownedByAnotherUser(ownerUserID)
        }
        if ownerUserID == nil {
            guard claimingOwnership || allowUnowned else {
                throw GatewayHelperControllerError.notRunning
            }
            if claimingOwnership {
                ownerUserID = session.userID
            }
        }
        if ownerUserID == session.userID {
            attachedSessionIDs.insert(session.id)
            cancelLeaseStop()
        }
    }

    private func handleSessionInvalidation(_ session: GatewayHelperSession) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard ownerUserID == session.userID else { return }
        attachedSessionIDs.remove(session.id)
        guard attachedSessionIDs.isEmpty, currentConfiguration != nil else { return }
        scheduleLeaseStop()
    }

    private func scheduleLeaseStop() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard leaseCancellation == nil else { return }
        leaseGeneration &+= 1
        let generation = leaseGeneration
        leaseCancellation = leaseScheduler.schedule(after: leaseDuration) { [weak self] in
            guard let self else { return }
            queue.async { [weak self] in
                self?.expireLease(generation: generation)
            }
        }
    }

    private func expireLease(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard generation == leaseGeneration, attachedSessionIDs.isEmpty else { return }
        leaseCancellation = nil
        do {
            try stopAndClearOwnership()
        } catch {
            fputs("helper Gateway lease stop error: \(error.localizedDescription)\n", stderr)
            let networkInstancesRemain = hasNetworkInstances()
            if networkInstancesRemain {
                scheduleLeaseStop()
                return
            }
            clearRuntimeState()
            idleExitHandler()
            return
        }
        if !hasNetworkInstances() {
            idleExitHandler()
        }
    }

    private func stopAndClearOwnership() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        cancelLeaseStop()
        try ffi.stopSync()
        clearRuntimeState()
    }

    private func releaseOwnershipIfStopped() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard (try? ffi.statusSync().state) == .stopped else { return }
        clearRuntimeState()
    }

    private func clearRuntimeState() {
        dispatchPrecondition(condition: .onQueue(queue))
        currentConfiguration = nil
        currentFFIConfiguration = nil
        ownerUserID = nil
        attachedSessionIDs.removeAll()
        cancelLeaseStop()
    }

    private func cancelLeaseStop() {
        dispatchPrecondition(condition: .onQueue(queue))
        leaseGeneration &+= 1
        leaseCancellation?.cancel()
        leaseCancellation = nil
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        dispatchPrecondition(condition: .onQueue(queue))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw EasyTierCoreError.invalidResponse("Failed to encode Gateway status as UTF-8 JSON.")
        }
        return string
    }

    private func setPermissions(_ permissions: mode_t, at url: URL) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard chmod(url.path, permissions) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
