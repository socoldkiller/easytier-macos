import Foundation
import Synchronization
import Testing
@testable import GatewayRuntime
@testable import EasyTierShared

@Suite(.serialized)
struct StaticGatewayFFITests {
    @Test func ffiWrapperRunsACompleteHighPortLifecycle() throws {
        let ffi = StaticGatewayFFIClient()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StaticGatewayFFITests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? ffi.stopSync()
            try? FileManager.default.removeItem(at: root)
        }
        try? ffi.stopSync()

        var configuration = gatewayRuntimeTestConfiguration()
        var runtime = GatewayFFIConfiguration(
            configuration: configuration,
            storageDirectory: root.path,
            httpListener: "127.0.0.1:0",
            httpsListener: "127.0.0.1:0"
        )

        try ffi.startSync(configuration: runtime)
        let running = try ffi.statusSync()
        #expect(running.state == .running)
        #expect(running.listeners.http?.hasPrefix("127.0.0.1:") == true)
        #expect(running.listeners.https?.hasPrefix("127.0.0.1:") == true)

        configuration.acme.contactEmail = "renewals@example.com"
        runtime = GatewayFFIConfiguration(
            configuration: configuration,
            storageDirectory: root.path,
            httpListener: "127.0.0.1:0",
            httpsListener: "127.0.0.1:0"
        )
        try ffi.applySync(configuration: runtime)
        #expect(try ffi.statusSync().configGeneration >= running.configGeneration)

        try ffi.requestRenewalSync(certificateID: nil)
        try ffi.stopSync()
        #expect(try ffi.statusSync().state == .stopped)
    }
}

@Test func helperControllerReconcilesIdempotentHotAndRestartChanges() async throws {
    let fixture = GatewayHelperFixture()
    defer { fixture.cleanup() }
    let session = GatewayHelperSession(userID: 501)
    let staging = gatewayRuntimeTestConfiguration()

    try await fixture.controller.start(
        configurationJSON: encode(staging),
        session: session
    )
    try await fixture.controller.start(
        configurationJSON: encode(staging),
        session: session
    )

    var hotUpdate = staging
    hotUpdate.acme.contactEmail = "renewals@example.com"
    try await fixture.controller.apply(
        configurationJSON: encode(hotUpdate),
        session: session
    )

    var restartUpdate = hotUpdate
    restartUpdate.acme.directory = .letsencryptProduction
    try await fixture.controller.apply(
        configurationJSON: encode(restartUpdate),
        session: session
    )

    #expect(fixture.ffi.callNames() == ["start", "apply", "stop", "start"])
    let startConfigurations = fixture.ffi.startConfigurations()
    #expect(startConfigurations.count == 2)
    #expect(startConfigurations.allSatisfy { $0.listeners.http == "0.0.0.0:80" })
    #expect(startConfigurations.allSatisfy { $0.listeners.https == "0.0.0.0:443" })
    #expect(startConfigurations.allSatisfy {
        $0.storageDirectory.hasSuffix("/501/runtime")
    })
    let sharedPermissions = try FileManager.default.attributesOfItem(
        atPath: fixture.root.path
    )[.posixPermissions] as? NSNumber
    let userPermissions = try FileManager.default.attributesOfItem(
        atPath: fixture.root.appendingPathComponent("501").path
    )[.posixPermissions] as? NSNumber
    let runtimePermissions = try FileManager.default.attributesOfItem(
        atPath: fixture.root.appendingPathComponent("501/runtime").path
    )[.posixPermissions] as? NSNumber
    #expect(sharedPermissions?.intValue == 0o755)
    #expect(userPermissions?.intValue == 0o700)
    #expect(runtimePermissions?.intValue == 0o700)
}

@Test func helperControllerRejectsAnotherUserAndUnknownRenewalCertificate() async throws {
    let fixture = GatewayHelperFixture()
    defer { fixture.cleanup() }
    let owner = GatewayHelperSession(userID: 501)
    let otherUser = GatewayHelperSession(userID: 502)
    try await fixture.controller.start(
        configurationJSON: encode(gatewayRuntimeTestConfiguration()),
        session: owner
    )

    await #expect(throws: GatewayHelperControllerError.self) {
        try await fixture.controller.status(session: otherUser)
    }
    await #expect(throws: GatewayHelperControllerError.self) {
        try await fixture.controller.requestRenewal(
            certificateID: "missing-cert",
            session: owner
        )
    }
}

@Test func failedInitialStoragePreparationReleasesGatewayOwnership() async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("GatewayHelperControllerTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let unusableStorageRoot = parent.appendingPathComponent("storage-root")
    try Data().write(to: unusableStorageRoot)

    let controller = GatewayHelperController(
        ffi: FakeGatewayFFI(),
        storageRoot: unusableStorageRoot,
        leaseScheduler: ManualGatewayLeaseScheduler()
    )
    let owner = GatewayHelperSession(userID: 501)
    let otherUser = GatewayHelperSession(userID: 502)

    await #expect(throws: Error.self) {
        try await controller.start(
            configurationJSON: encode(gatewayRuntimeTestConfiguration()),
            session: owner
        )
    }

    let status = try JSONDecoder().decode(
        GatewayStatus.self,
        from: Data(try await controller.status(session: otherUser).utf8)
    )
    #expect(status.state == .stopped)
}

@Test func helperControllerRollsBackWhenImmutableRestartFails() async throws {
    let fixture = GatewayHelperFixture()
    defer { fixture.cleanup() }
    let session = GatewayHelperSession(userID: 501)
    let staging = gatewayRuntimeTestConfiguration()
    try await fixture.controller.start(
        configurationJSON: encode(staging),
        session: session
    )

    fixture.ffi.failNextStarts(1)
    var production = staging
    production.acme.directory = .letsencryptProduction

    await #expect(throws: GatewayHelperControllerError.self) {
        try await fixture.controller.apply(
            configurationJSON: encode(production),
            session: session
        )
    }
    #expect(fixture.ffi.callNames() == ["start", "stop", "start", "start"])
    #expect(try JSONDecoder().decode(
        GatewayStatus.self,
        from: Data(try await fixture.controller.status(session: session).utf8)
    ).state == .running)
}

@Test func helperLeaseStopsAfterTheLastSessionAndReconnectCancelsTheStop() async throws {
    let scheduler = ManualGatewayLeaseScheduler()
    let idleExitCount = Mutex(0)
    let fixture = GatewayHelperFixture(
        scheduler: scheduler,
        idleExitHandler: { idleExitCount.withLock { $0 += 1 } }
    )
    defer { fixture.cleanup() }
    let first = GatewayHelperSession(userID: 501)
    let second = GatewayHelperSession(userID: 501)
    let configurationJSON = encode(gatewayRuntimeTestConfiguration())

    try await fixture.controller.start(configurationJSON: configurationJSON, session: first)
    await fixture.controller.sessionDidInvalidate(first)
    try await fixture.controller.start(configurationJSON: configurationJSON, session: second)
    scheduler.fire()
    #expect(try JSONDecoder().decode(
        GatewayStatus.self,
        from: Data(try await fixture.controller.status(session: second).utf8)
    ).state == .running)
    #expect(!fixture.ffi.callNames().contains("stop"))

    await fixture.controller.sessionDidInvalidate(second)
    scheduler.fire()
    let stopped = try JSONDecoder().decode(
        GatewayStatus.self,
        from: Data(try await fixture.controller.status(session: second).utf8)
    )
    #expect(stopped.state == .stopped)
    #expect(fixture.ffi.callNames().contains("stop"))
    #expect(idleExitCount.withLock { $0 } == 1)
}

@Test func failedLeaseStopRetriesWhileNetworkInstancesRemain() async throws {
    let scheduler = ManualGatewayLeaseScheduler()
    let networkInstancesRemain = Mutex(true)
    let idleExitCount = Mutex(0)
    let fixture = GatewayHelperFixture(
        scheduler: scheduler,
        hasNetworkInstances: { networkInstancesRemain.withLock { $0 } },
        idleExitHandler: { idleExitCount.withLock { $0 += 1 } }
    )
    defer { fixture.cleanup() }
    let owner = GatewayHelperSession(userID: 501)
    let otherUser = GatewayHelperSession(userID: 502)
    try await fixture.controller.start(
        configurationJSON: encode(gatewayRuntimeTestConfiguration()),
        session: owner
    )
    fixture.ffi.failNextStops(1)

    await fixture.controller.sessionDidInvalidate(owner)
    scheduler.fire()
    await #expect(throws: GatewayHelperControllerError.self) {
        try await fixture.controller.status(session: otherUser)
    }
    #expect(fixture.ffi.callNames().filter { $0 == "stop" }.count == 1)
    #expect(idleExitCount.withLock { $0 } == 0)

    networkInstancesRemain.withLock { $0 = false }
    scheduler.fire()
    let stopped = try JSONDecoder().decode(
        GatewayStatus.self,
        from: Data(try await fixture.controller.status(session: otherUser).utf8)
    )
    #expect(stopped.state == .stopped)
    #expect(fixture.ffi.callNames().filter { $0 == "stop" }.count == 2)
    #expect(idleExitCount.withLock { $0 } == 1)
}

@Test func helperControllerMigratesLegacyGatewayStorage() async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("GatewayStorageMigrationTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let legacyRoot = parent.appendingPathComponent("legacy", isDirectory: true)
    let newRoot = parent.appendingPathComponent("coldkiller/Gateway", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
    let marker = legacyRoot.appendingPathComponent("existing-certificate.pem")
    try Data("certificate".utf8).write(to: marker)

    let controller = GatewayHelperController(
        ffi: FakeGatewayFFI(),
        storageRoot: newRoot,
        legacyStorageRoot: legacyRoot
    )
    try await controller.start(
        configurationJSON: encode(gatewayRuntimeTestConfiguration()),
        session: GatewayHelperSession(userID: 501)
    )

    #expect(!FileManager.default.fileExists(atPath: legacyRoot.path))
    #expect(
        FileManager.default.fileExists(
            atPath: newRoot.appendingPathComponent("existing-certificate.pem").path
        )
    )
}

private struct GatewayHelperFixture {
    let root: URL
    let ffi: FakeGatewayFFI
    let controller: GatewayHelperController

    init(
        scheduler: any GatewayLeaseScheduling = ManualGatewayLeaseScheduler(),
        hasNetworkInstances: @escaping @Sendable () -> Bool = { false },
        idleExitHandler: @escaping @Sendable () -> Void = {}
    ) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GatewayHelperControllerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        ffi = FakeGatewayFFI()
        controller = GatewayHelperController(
            ffi: ffi,
            storageRoot: root,
            leaseDuration: 10,
            leaseScheduler: scheduler,
            hasNetworkInstances: hasNetworkInstances,
            idleExitHandler: idleExitHandler
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class FakeGatewayFFI: GatewayFFIRuntimeClient, Sendable {
    private struct State: Sendable {
        var running = false
        var calls: [String] = []
        var starts: [GatewayFFIConfiguration] = []
        var current: GatewayFFIConfiguration?
        var startFailuresRemaining = 0
        var stopFailuresRemaining = 0
    }

    private let state = Mutex(State())

    func startSync(configuration: GatewayFFIConfiguration) throws {
        try state.withLock { state in
            state.calls.append("start")
            state.starts.append(configuration)
            if state.startFailuresRemaining > 0 {
                state.startFailuresRemaining -= 1
                throw FakeGatewayError.startFailed
            }
            state.running = true
            state.current = configuration
        }
    }

    func applySync(configuration: GatewayFFIConfiguration) throws {
        state.withLock { state in
            state.calls.append("apply")
            state.current = configuration
        }
    }

    func stopSync() throws {
        try state.withLock { state in
            state.calls.append("stop")
            if state.stopFailuresRemaining > 0 {
                state.stopFailuresRemaining -= 1
                throw FakeGatewayError.stopFailed
            }
            state.running = false
            state.current = nil
        }
    }

    func statusSync() throws -> GatewayStatus {
        state.withLock { state in
            var status = GatewayStatus.stopped
            if state.running {
                status.state = .running
                status.listeners = GatewayListenerStatus(
                    http: state.current?.listeners.http,
                    https: state.current?.listeners.https
                )
            }
            return status
        }
    }

    func requestRenewalSync(certificateID: String?) throws {
        state.withLock { $0.calls.append("renew") }
    }

    func callNames() -> [String] {
        state.withLock { $0.calls }
    }

    func startConfigurations() -> [GatewayFFIConfiguration] {
        state.withLock { $0.starts }
    }

    func failNextStarts(_ count: Int) {
        state.withLock { $0.startFailuresRemaining = count }
    }

    func failNextStops(_ count: Int) {
        state.withLock { $0.stopFailuresRemaining = count }
    }
}

private enum FakeGatewayError: Error {
    case startFailed
    case stopFailed
}

private final class ManualGatewayLeaseScheduler: GatewayLeaseScheduling, Sendable {
    private struct State: Sendable {
        var operation: (@Sendable () -> Void)?
        var cancelled = false
    }

    private let state = Mutex(State())

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) -> any GatewayLeaseCancellation {
        state.withLock { state in
            state.operation = operation
            state.cancelled = false
        }
        return ManualGatewayLeaseCancellation(scheduler: self)
    }

    func fire() {
        let operation = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.cancelled else { return nil }
            let operation = state.operation
            state.operation = nil
            return operation
        }
        operation?()
    }

    func cancelScheduledOperation() {
        state.withLock { $0.cancelled = true }
    }
}

private final class ManualGatewayLeaseCancellation: GatewayLeaseCancellation, Sendable {
    private let scheduler: ManualGatewayLeaseScheduler

    init(scheduler: ManualGatewayLeaseScheduler) {
        self.scheduler = scheduler
    }

    func cancel() {
        scheduler.cancelScheduledOperation()
    }
}

private func gatewayRuntimeTestConfiguration(
    directory: GatewayACMEDirectory = .letsencryptStaging
) -> GatewayConfiguration {
    GatewayConfiguration(
        acme: GatewayACMEConfiguration(
            directory: directory,
            contactEmail: "ops@example.com",
            termsOfServiceAgreed: true
        ),
        certificates: [],
        routes: []
    )
}

private func encode(_ configuration: GatewayConfiguration) -> String {
    let data = try! JSONEncoder().encode(configuration)
    return String(decoding: data, as: UTF8.self)
}
