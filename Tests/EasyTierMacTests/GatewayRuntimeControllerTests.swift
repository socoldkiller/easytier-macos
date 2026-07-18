import Foundation
import Testing
@testable import EasyTierMac
@testable import EasyTierShared

@MainActor
@Test func enabledGatewayConfigurationStartsAndLifecycleStopPreservesDesire() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GatewayRuntimeControllerTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GatewayConfigurationStore(
        fileURL: root.appendingPathComponent("gateway/config.json")
    )
    let configuration = gatewayControllerTestConfiguration()
    try await store.save(
        GatewayPersistedState(enabled: true, configuration: configuration)
    )
    let client = RecordingGatewayClient()
    let controller = GatewayRuntimeController(
        client: client,
        configurationStore: store,
        helperRegistration: nil
    )

    await controller.load()
    await controller.reconcile()

    #expect(controller.desiredEnabled)
    #expect(controller.status.state == .running)
    #expect(await client.callNames() == ["start", "status"])

    await controller.stopForLifecycle()
    let savedAfterStop = try await store.load()
    #expect(controller.status.state == .stopped)
    #expect(savedAfterStop?.enabled == true)
    #expect(await client.callNames() == ["start", "status", "stop"])
}

@MainActor
@Test func disabledGatewayConfigurationLoadsWithoutStartingHelper() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GatewayRuntimeControllerTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GatewayConfigurationStore(
        fileURL: root.appendingPathComponent("gateway/config.json")
    )
    try await store.save(
        GatewayPersistedState(
            enabled: false,
            configuration: gatewayControllerTestConfiguration()
        )
    )
    let client = RecordingGatewayClient()
    let controller = GatewayRuntimeController(
        client: client,
        configurationStore: store,
        helperRegistration: nil
    )

    await controller.load()
    await controller.reconcile()
    await controller.stopForLifecycle()

    #expect(!controller.desiredEnabled)
    #expect(controller.status.state == .stopped)
    #expect(await client.callNames().isEmpty)
}

@MainActor
@Test func savingEnabledGatewayConfigurationPersistsBeforeReconcile() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GatewayRuntimeControllerTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GatewayConfigurationStore(
        fileURL: root.appendingPathComponent("gateway/config.json")
    )
    let client = RecordingGatewayClient()
    let controller = GatewayRuntimeController(
        client: client,
        configurationStore: store,
        helperRegistration: nil
    )
    let configuration = gatewayControllerTestConfiguration()

    try await controller.setConfiguration(configuration, enabled: true)
    let saved = try await store.load()

    #expect(saved?.configuration == configuration)
    #expect(controller.status.state == .running)
    #expect(await client.callNames() == ["start", "status"])
}

@MainActor
@Test func enablingStateDoesNotOverwriteAConcurrentConfigurationSave() async throws {
    let initialConfiguration = gatewayControllerTestConfiguration()
    let store = BlockingGatewayConfigurationStore(
        state: GatewayPersistedState(
            enabled: true,
            configuration: initialConfiguration
        )
    )
    let client = RecordingGatewayClient()
    let controller = GatewayRuntimeController(
        client: client,
        configurationStore: store,
        helperRegistration: nil
    )
    await controller.load()
    await store.blockNextSave()

    var updatedConfiguration = initialConfiguration
    updatedConfiguration.acme.contactEmail = "updated@example.com"
    let configurationTask = Task { @MainActor in
        try await controller.setConfiguration(updatedConfiguration, enabled: true)
    }
    await store.waitUntilSaveIsBlocked()

    let enabledTask = Task { @MainActor in
        try await controller.setEnabled(false)
    }
    await Task.yield()
    await store.releaseBlockedSave()

    try await configurationTask.value
    try await enabledTask.value
    let saved = await store.currentState()
    #expect(saved?.enabled == false)
    #expect(saved?.configuration == updatedConfiguration)
}

private actor RecordingGatewayClient: GatewayClient {
    private var calls: [String] = []
    private var isRunning = false

    func start(configuration: GatewayConfiguration) async throws {
        calls.append("start")
        isRunning = true
    }

    func apply(configuration: GatewayConfiguration) async throws {
        calls.append("apply")
    }

    func stop() async throws {
        calls.append("stop")
        isRunning = false
    }

    func status() async throws -> GatewayStatus {
        calls.append("status")
        var status = GatewayStatus.stopped
        status.state = isRunning ? .running : .stopped
        return status
    }

    func requestRenewal(certificateID: String?) async throws {
        calls.append("renew")
    }

    func callNames() -> [String] { calls }
}

private actor BlockingGatewayConfigurationStore: GatewayConfigurationStoring {
    private var state: GatewayPersistedState?
    private var shouldBlockNextSave = false
    private var blockedSave: CheckedContinuation<Void, Never>?
    private var blockedSaveWaiters: [CheckedContinuation<Void, Never>] = []

    init(state: GatewayPersistedState?) {
        self.state = state
    }

    func load() -> GatewayPersistedState? {
        state
    }

    func save(_ newState: GatewayPersistedState) async {
        if shouldBlockNextSave {
            shouldBlockNextSave = false
            await withCheckedContinuation { continuation in
                blockedSave = continuation
                let waiters = blockedSaveWaiters
                blockedSaveWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        state = newState
    }

    func blockNextSave() {
        shouldBlockNextSave = true
    }

    func waitUntilSaveIsBlocked() async {
        guard blockedSave == nil else { return }
        await withCheckedContinuation { continuation in
            blockedSaveWaiters.append(continuation)
        }
    }

    func releaseBlockedSave() {
        let continuation = blockedSave
        blockedSave = nil
        continuation?.resume()
    }

    func currentState() -> GatewayPersistedState? {
        state
    }
}

private func gatewayControllerTestConfiguration() -> GatewayConfiguration {
    GatewayConfiguration(
        acme: GatewayACMEConfiguration(
            directory: .letsencryptStaging,
            contactEmail: "ops@example.com",
            termsOfServiceAgreed: true
        ),
        certificates: [],
        routes: []
    )
}
