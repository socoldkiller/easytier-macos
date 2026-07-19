import Observation
import Testing
@testable import EasyTierShared

@MainActor
@Test func configApplyCoordinatorCoalescesRapidChanges() async throws {
    let coordinator = ConfigApplyCoordinator(
        successDisplayDuration: .seconds(1)
    )
    var applied: [LocalConfigApplyRequest] = []
    let first = LocalConfigApplyRequest(
        configID: "config-id",
        config: NetworkConfig(instance_id: "config-id", network_name: "first"),
        replacing: nil
    )
    let second = LocalConfigApplyRequest(
        configID: "config-id",
        config: NetworkConfig(instance_id: "config-id", network_name: "second"),
        replacing: nil
    )

    coordinator.schedule(first) { request in
        applied.append(request)
        return .saved
    }
    coordinator.schedule(second) { request in
        applied.append(request)
        return .saved
    }

    await waitForPhase(.applied, in: coordinator)

    #expect(applied == [second])
    #expect(coordinator.phase == .applied)
}

@MainActor
@Test func configApplyCoordinatorFlushesPendingApply() async {
    let coordinator = ConfigApplyCoordinator(
        successDisplayDuration: .seconds(1)
    )
    var applied: [LocalConfigApplyRequest] = []
    let request = LocalConfigApplyRequest(
        configID: "config-id",
        config: NetworkConfig(instance_id: "config-id"),
        replacing: nil
    )
    coordinator.schedule(request) { request in
        applied.append(request)
        return .saved
    }

    await coordinator.flush()

    #expect(applied == [request])
    #expect(coordinator.phase == .applied)
}

@MainActor
@Test func configApplyCoordinatorTracksWhichConfigOwnsItsToolbarStatus() {
    let coordinator = ConfigApplyCoordinator(
        successDisplayDuration: .seconds(1)
    )
    let first = LocalConfigApplyRequest(
        configID: "first-config",
        config: NetworkConfig(instance_id: "first-config"),
        replacing: nil
    )
    let second = LocalConfigApplyRequest(
        configID: "second-config",
        config: NetworkConfig(instance_id: "second-config"),
        replacing: nil
    )

    coordinator.schedule(first) { _ in .saved }
    #expect(coordinator.targetConfigID == "first-config")

    coordinator.schedule(second) { _ in .saved }
    #expect(coordinator.targetConfigID == "second-config")

    coordinator.cancelPending()
    #expect(coordinator.targetConfigID == nil)
    #expect(coordinator.phase == .idle)
}

@MainActor
@Test func configApplyCoordinatorRunsOneFollowUpForChangesMadeDuringApply() async throws {
    let coordinator = ConfigApplyCoordinator(
        successDisplayDuration: .seconds(1)
    )
    var appliedNames: [String] = []
    let firstApplyStarted = OneShotEvent()
    let allowFirstApplyToFinish = OneShotEvent()
    let first = LocalConfigApplyRequest(
        configID: "config-id",
        config: NetworkConfig(instance_id: "config-id", network_name: "first"),
        replacing: nil
    )
    let second = LocalConfigApplyRequest(
        configID: "config-id",
        config: NetworkConfig(instance_id: "config-id", network_name: "second"),
        replacing: nil
    )

    coordinator.schedule(first) { request in
        appliedNames.append(request.config.network_name)
        await firstApplyStarted.signal()
        await allowFirstApplyToFinish.wait()
        return .saved
    }
    await firstApplyStarted.wait()

    coordinator.schedule(second) { request in
        appliedNames.append(request.config.network_name)
        return .saved
    }
    await allowFirstApplyToFinish.signal()

    await waitForPhase(.applied, in: coordinator)

    #expect(appliedNames == ["first", "second"])
    #expect(coordinator.phase == .applied)
}

@MainActor
private func waitForPhase(
    _ expectedPhase: ConfigApplyCoordinator.Phase,
    in coordinator: ConfigApplyCoordinator
) async {
    while coordinator.phase != expectedPhase {
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = coordinator.phase
            } onChange: {
                continuation.resume()
            }
        }
    }
}

private actor OneShotEvent {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}
