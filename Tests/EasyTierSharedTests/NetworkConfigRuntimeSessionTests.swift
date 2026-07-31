import Foundation
import Testing
@testable import EasyTierShared

@MainActor
@Test func runSelectedConfigKeepsPendingInstanceStartingWhenRuntimeListIsInitiallyEmpty() async throws {
    let client = PendingStartClient()
    let config = NetworkConfig(instance_id: "pending-id", network_name: "pending-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()

    let selected = try #require(store.selectedRunningInstance)
    #expect(client.didRun)
    #expect(selected.instance_id == config.instance_id)
    #expect(selected.name == config.network_name)
    #expect(selected.running)
    #expect(selected.detail?.running == true)
    #expect(store.selectedConfigCanStop)
    #expect(store.selectedConfigIsRunning)
    #expect(!store.selectedConfigIsReady)
    #expect(store.selectedRuntimeReadinessPhase == .starting)
    #expect(store.lastError == nil)
}

@MainActor
@Test func runtimeSessionControllerKeepsPendingStartUntilRuntimeAppears() async throws {
    let client = RecordingToggleClient()
    let sleepPreventer = RecordingSystemSleepPreventer()
    let controller = RuntimeSessionController(
        runtimeClient: client,
        helperRegistration: nil,
        systemSleepPreventer: sleepPreventer
    )
    let config = NetworkConfig(instance_id: "pending-id", network_name: "pending-network")

    controller.recordPendingStart(for: config)
    let pendingResult = try await controller.refreshRuntime(
        currentInstances: [],
        currentRuntimeDetails: [:],
        currentStatusMetrics: [:],
        currentTrafficSamples: [:],
        currentTrafficSamplingStatus: [:],
        selectedTab: .status
    )
    let pendingChange = try #require(pendingResult)

    #expect(pendingChange.state.instances.map(\.instance_id) == [config.instance_id])
    #expect(pendingChange.state.instances.first?.detail?.running == true)
    #expect(pendingChange.state.instances.first?.runtimeReadinessPhase(requiresTUN: true) == .starting)
    #expect(sleepPreventer.isPreventingSystemSleep)

    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(hostname: "local", peer_id: 7),
            running: true,
            instance_id: config.instance_id
        ),
    ]
    let startingRuntimeResult = try await controller.refreshRuntime(
        currentInstances: pendingChange.state.instances,
        currentRuntimeDetails: pendingChange.state.runtimeDetails,
        currentStatusMetrics: pendingChange.state.statusMetricsByInstance,
        currentTrafficSamples: pendingChange.state.trafficSamplesByInstance,
        currentTrafficSamplingStatus: pendingChange.state.trafficSamplingStatusByInstance,
        selectedTab: .status
    )
    let startingRuntimeChange = try #require(startingRuntimeResult)

    #expect(startingRuntimeChange.state.instances.first?.detail?.my_node_info != nil)
    #expect(startingRuntimeChange.state.instances.first?.runtimeReadinessPhase(requiresTUN: true) == .starting)

    client.collectError = EasyTierCoreError.operationFailed("temporary collect failure")
    let failedCollectResult = try await controller.refreshRuntime(
        currentInstances: startingRuntimeChange.state.instances,
        currentRuntimeDetails: startingRuntimeChange.state.runtimeDetails,
        currentStatusMetrics: startingRuntimeChange.state.statusMetricsByInstance,
        currentTrafficSamples: startingRuntimeChange.state.trafficSamplesByInstance,
        currentTrafficSamplingStatus: startingRuntimeChange.state.trafficSamplingStatusByInstance,
        selectedTab: .status
    )
    let failedCollectChange = try #require(failedCollectResult)

    #expect(failedCollectChange.state.instances.map(\.instance_id) == [config.instance_id])
    #expect(failedCollectChange.state.instances.first?.runtimeReadinessPhase(requiresTUN: true) == .starting)
    #expect(sleepPreventer.isPreventingSystemSleep)

    client.collectError = nil
    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
            running: true,
            instance_id: config.instance_id
        ),
    ]
    let runningResult = try await controller.refreshRuntime(
        currentInstances: failedCollectChange.state.instances,
        currentRuntimeDetails: failedCollectChange.state.runtimeDetails,
        currentStatusMetrics: failedCollectChange.state.statusMetricsByInstance,
        currentTrafficSamples: failedCollectChange.state.trafficSamplesByInstance,
        currentTrafficSamplingStatus: failedCollectChange.state.trafficSamplingStatusByInstance,
        selectedTab: .status
    )
    let runningChange = try #require(runningResult)

    #expect(runningChange.state.instances.map(\.instance_id) == [config.instance_id])
    #expect(runningChange.state.instances.map(\.name) == [config.network_name])
    #expect(runningChange.state.instances.first?.runtimeReadinessPhase(requiresTUN: true) == .ready)
}

@MainActor
@Test func pendingStartCanBeStoppedWithoutStartingAgain() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "pending-id", network_name: "pending-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()
    #expect(store.selectedRuntimeReadinessPhase == .starting)

    await store.toggleSelectedConfigConnection()

    #expect(client.runConfigs.map(\.instance_id) == [config.instance_id])
    #expect(client.stoppedInstanceNames == [[config.network_name]])
    #expect(!store.selectedConfigCanStop)
    #expect(!store.selectedConfigIsRunning)
    #expect(store.selectedRuntimeReadinessPhase == .stopped)
}

@MainActor
@Test func newerRuntimeRefreshWinsWhenOlderRefreshCompletesLast() async {
    let client = ControlledRuntimeRefreshClient()
    let config = NetworkConfig(instance_id: "refresh-id", network_name: "refresh-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let olderRefresh = Task { await store.refreshRuntime() }
    await client.waitForRequest(0)
    let newerRefresh = Task { await store.refreshRuntime() }
    await client.waitForRequest(1)

    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    await client.resolveRequest(1, with: [config.network_name: readyDetail])
    await newerRefresh.value
    await client.resolveRequest(0, with: [:])
    await olderRefresh.value

    #expect(store.selectedRuntimeReadinessPhase == .ready)
    #expect(store.selectedConfigCanStop)
    #expect(store.selectedRuntimeDetail == readyDetail)
}

@MainActor
@Test func completedRuntimeRefreshCanPublishWhileNewerRefreshIsStillInFlight() async {
    let client = ControlledRuntimeRefreshClient()
    let config = NetworkConfig(instance_id: "completion-id", network_name: "completion-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let firstRefresh = Task { await store.refreshRuntime() }
    await client.waitForRequest(0)
    let secondRefresh = Task { await store.refreshRuntime() }
    await client.waitForRequest(1)

    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    await client.resolveRequest(0, with: [config.network_name: readyDetail])
    await firstRefresh.value

    #expect(store.selectedRuntimeReadinessPhase == .ready)

    await client.resolveRequest(1, with: [config.network_name: readyDetail])
    await secondRefresh.value
    #expect(store.selectedRuntimeReadinessPhase == .ready)
}

@MainActor
@Test func staleRuntimeRefreshDoesNotClearNewPendingStart() async throws {
    let client = RecordingToggleClient()
    let controller = RuntimeSessionController(
        runtimeClient: client,
        helperRegistration: nil,
        systemSleepPreventer: RecordingSystemSleepPreventer()
    )
    let config = NetworkConfig(instance_id: "pending-generation-id", network_name: "pending-generation-network")
    controller.recordPendingStart(for: config)
    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "stale", peer_id: 7),
            running: true,
            instance_id: config.instance_id
        ),
    ]

    let staleChange = try await controller.refreshRuntime(
        currentInstances: [],
        currentRuntimeDetails: [:],
        currentStatusMetrics: [:],
        currentTrafficSamples: [:],
        currentTrafficSamplingStatus: [:],
        selectedTab: .status,
        shouldApply: { false }
    )
    #expect(staleChange == nil)

    client.networkInfos = [:]
    let currentResult = try await controller.refreshRuntime(
        currentInstances: [],
        currentRuntimeDetails: [:],
        currentStatusMetrics: [:],
        currentTrafficSamples: [:],
        currentTrafficSamplingStatus: [:],
        selectedTab: .status
    )
    let currentChange = try #require(currentResult)

    #expect(currentChange.state.instances.map(\.instance_id) == [config.instance_id])
    #expect(currentChange.state.instances.first?.runtimeReadinessPhase(requiresTUN: true) == .starting)
}

@MainActor
@Test func noTunRuntimeClearsPendingWithoutWaitingForVirtualIPv4() async throws {
    let client = RecordingToggleClient()
    let controller = RuntimeSessionController(
        runtimeClient: client,
        helperRegistration: nil,
        systemSleepPreventer: RecordingSystemSleepPreventer()
    )
    let config = NetworkConfig(
        instance_id: "no-tun-pending-id",
        network_name: "no-tun-pending-network",
        no_tun: true
    )
    controller.recordPendingStart(for: config)
    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(hostname: "local", peer_id: 7),
            running: true,
            instance_id: config.instance_id
        ),
    ]

    let readyResult = try await controller.refreshRuntime(
        currentInstances: [],
        currentRuntimeDetails: [:],
        currentStatusMetrics: [:],
        currentTrafficSamples: [:],
        currentTrafficSamplingStatus: [:],
        selectedTab: .status
    )
    let readyChange = try #require(readyResult)
    #expect(readyChange.state.instances.first?.runtimeReadinessPhase(requiresTUN: false) == .ready)

    client.networkInfos = [:]
    let stoppedResult = try await controller.refreshRuntime(
        currentInstances: readyChange.state.instances,
        currentRuntimeDetails: readyChange.state.runtimeDetails,
        currentStatusMetrics: readyChange.state.statusMetricsByInstance,
        currentTrafficSamples: readyChange.state.trafficSamplesByInstance,
        currentTrafficSamplingStatus: readyChange.state.trafficSamplingStatusByInstance,
        selectedTab: .status
    )
    let stoppedChange = try #require(stoppedResult)
    #expect(stoppedChange.state.instances.isEmpty)
}

@MainActor
@Test func runtimeSessionDoesNotPollXPCWhileHelperApprovalIsPending() async throws {
    let client = RecordingToggleClient()
    let backend = HelperRegistrationBackendSpy(status: .requiresApproval)
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)
    await registration.refresh()
    let controller = RuntimeSessionController(
        runtimeClient: client,
        helperRegistration: registration,
        systemSleepPreventer: RecordingSystemSleepPreventer()
    )

    _ = try await controller.refreshRuntime(
        currentInstances: [],
        currentRuntimeDetails: [:],
        currentStatusMetrics: [:],
        currentTrafficSamples: [:],
        currentTrafficSamplingStatus: [:],
        selectedTab: .status
    )

    #expect(client.collectCount == 0)
}

@MainActor
@Test func runtimeMutationInvalidatesRefreshThatStartedBeforeFailedStop() async {
    let client = ControlledRuntimeRefreshClient()
    let config = NetworkConfig(instance_id: "generation-id", network_name: "generation-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let readyInstance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: readyDetail
    )
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [readyInstance]
    store.runtimeDetails = [config.network_name: readyDetail]

    let staleRefresh = Task { await store.refreshRuntime() }
    await client.waitForRequest(0)
    await client.setStopErrorMessage("stop failed")

    let stopTask = Task { await store.stopSelectedConfig() }
    await client.waitForRequest(1)
    await client.resolveRequest(1, with: [config.network_name: readyDetail])
    await stopTask.value
    await client.resolveRequest(0, with: [:])
    await staleRefresh.value

    #expect(store.lastError?.contains("stop failed") == true)
    #expect(store.selectedRuntimeReadinessPhase == .ready)
    #expect(store.selectedRunningInstance == readyInstance)
}

@MainActor
@Test func ambientRefreshDoesNotPublishWhileStopIsInProgress() async {
    let config = NetworkConfig(instance_id: "stop-lock-id", network_name: "stop-lock-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let client = BlockingRuntimeMutationClient(
        blocksStop: true,
        networkInfos: [config.network_name: readyDetail]
    )
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: readyDetail
    )]
    store.runtimeDetails = [config.network_name: readyDetail]

    let stopTask = Task { await store.stopSelectedConfig() }
    await client.waitForStopRequest()
    await store.refreshRuntime()

    let countsWhileStopping = await client.counts()
    #expect(countsWhileStopping.collects == 0)
    #expect(store.selectedRuntimeReadinessPhase == .ready)

    await client.failStop(message: "stop failed")
    await stopTask.value

    #expect(store.lastError?.contains("stop failed") == true)
    #expect(store.selectedRuntimeReadinessPhase == .ready)
}

@MainActor
@Test func restartRunFailureAfterSuccessfulStopPublishesStoppedState() async {
    let client = RecordingToggleClient()
    client.runError = EasyTierCoreError.operationFailed("restart run failed")
    let config = NetworkConfig(instance_id: "restart-failure-id", network_name: "restart-failure-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let readyInstance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: readyDetail
    )
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [readyInstance]
    store.runtimeDetails = [config.network_name: readyDetail]

    await store.restartSelectedConfig(replacing: readyInstance)

    #expect(client.stoppedInstanceNames == [[config.network_name]])
    #expect(client.runConfigs.map(\.instance_id) == [config.instance_id])
    #expect(store.lastError?.contains("restart run failed") == true)
    #expect(!store.selectedConfigCanStop)
    #expect(store.selectedRuntimeReadinessPhase == .stopped)
}

@MainActor
@Test func quitWaitsForInFlightRunThenStopsTheStartedRuntime() async {
    let client = BlockingRuntimeMutationClient(blocksRun: true)
    let config = NetworkConfig(instance_id: "quit-lock-id", network_name: "quit-lock-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let runTask = Task { await store.runSelectedConfig() }
    await client.waitForRunRequest()
    let quitTask = Task { await store.prepareForAppQuit() }
    for _ in 0..<10 { await Task.yield() }
    let countsBeforeRunCompletes = await client.counts()
    #expect(countsBeforeRunCompletes.retains == 0)

    await client.resumeRun()
    _ = await runTask.value
    await quitTask.value

    let counts = await client.counts()
    #expect(counts.runs == 1)
    #expect(counts.retains == 1)
    #expect(store.isQuitting)
    #expect(store.selectedRuntimeReadinessPhase == .stopped)
}

@MainActor
@Test func runtimeTransitionIsPublishedBeforeStartRPCAndClearedAfterRefresh() async {
    let client = BlockingRuntimeMutationClient(blocksRun: true)
    var config = NetworkConfig(instance_id: "transition-id", network_name: "transition-network")
    config.enable_magic_dns = true
    let store = EasyTierAppStore(client: client, storage: .isolatedForTesting())
    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let runTask = Task { await store.runSelectedConfig() }
    await client.waitForRunRequest()
    #expect(store.runtimeTransitionsByConfigID[config.instance_id] == .starting)

    await client.resumeRun()
    _ = await runTask.value
    #expect(store.runtimeTransitionsByConfigID.isEmpty)
}

@MainActor
@Test func queuedConnectionToggleReevaluatesStateAfterInFlightRun() async {
    let client = BlockingRuntimeMutationClient(blocksRun: true)
    let config = NetworkConfig(instance_id: "toggle-lock-id", network_name: "toggle-lock-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let firstToggle = Task { await store.toggleSelectedConfigConnection() }
    await client.waitForRunRequest()
    let secondToggle = Task { await store.toggleSelectedConfigConnection() }
    await client.resumeRun()
    await firstToggle.value
    await secondToggle.value

    let counts = await client.counts()
    #expect(counts.runs == 1)
    #expect(counts.stops == 1)
    #expect(store.selectedRuntimeReadinessPhase == .stopped)
}

@MainActor
@Test func userStopDuringWakeRefreshCancelsAutomaticRecovery() async {
    let client = ControlledRuntimeRefreshClient()
    let config = NetworkConfig(instance_id: "wake-cancel-id", network_name: "wake-cancel-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let readyInstance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: readyDetail
    )
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [readyInstance]
    store.runtimeDetails = [config.network_name: readyDetail]

    let sleepDate = Date(timeIntervalSince1970: 10_000)
    store.handleSystemWillSleep(now: sleepDate)
    let wakeTask = Task { await store.handleSystemDidWake(now: sleepDate.addingTimeInterval(31)) }
    await client.waitForRequest(0)

    let stopTask = Task { await store.stopSelectedConfig() }
    await client.waitForRequest(1)
    await client.resolveRequest(1, with: [:])
    await stopTask.value
    await client.resolveRequest(0, with: [config.network_name: readyDetail])
    await wakeTask.value

    let counts = await client.operationCounts()
    #expect(counts.runs == 0)
    #expect(counts.stops == 1)
    #expect(store.selectedRuntimeReadinessPhase == .stopped)
}

@MainActor
@Test func userStopAfterSleepBeginsCancelsAutomaticRecovery() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "sleep-generation-id", network_name: "sleep-generation-network")
    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let store = EasyTierAppStore(client: client)
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: readyDetail
        ),
    ]
    store.runtimeDetails = [config.network_name: readyDetail]
    client.networkInfos = [config.network_name: readyDetail]

    let sleepDate = Date(timeIntervalSince1970: 15_000)
    store.handleSystemWillSleep(now: sleepDate)
    client.networkInfos = [:]
    await store.stopSelectedConfig()
    await store.handleSystemDidWake(now: sleepDate.addingTimeInterval(31))

    #expect(client.stoppedInstanceNames == [[config.network_name]])
    #expect(client.runConfigs.isEmpty)
    #expect(store.selectedRuntimeReadinessPhase == .stopped)
}

@MainActor
@Test func stopInProgressWhenSleepBeginsIsNotAutomaticallyReversedAfterWake() async {
    let config = NetworkConfig(instance_id: "sleep-stop-id", network_name: "sleep-stop-network")
    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let client = BlockingRuntimeMutationClient(
        blocksStop: true,
        networkInfos: [config.network_name: readyDetail]
    )
    let store = EasyTierAppStore(client: client)
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: readyDetail
        ),
    ]
    store.runtimeDetails = [config.network_name: readyDetail]

    let stopTask = Task { await store.stopSelectedConfig() }
    await client.waitForStopRequest()
    let sleepDate = Date(timeIntervalSince1970: 20_000)
    store.handleSystemWillSleep(now: sleepDate)
    await client.setNetworkInfos([:])
    await client.resumeStop()
    await stopTask.value

    await store.handleSystemDidWake(now: sleepDate.addingTimeInterval(31))

    let counts = await client.counts()
    #expect(counts.runs == 0)
    #expect(counts.stops == 1)
    #expect(store.selectedRuntimeReadinessPhase == .stopped)
}
