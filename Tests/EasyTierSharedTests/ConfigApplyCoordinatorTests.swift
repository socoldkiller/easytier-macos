import Testing
@testable import EasyTierShared

@MainActor
@Test func configApplyCoordinatorCoalescesRapidChanges() async throws {
    let coordinator = ConfigApplyCoordinator(
        debounceDuration: .milliseconds(20),
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

    try await Task.sleep(for: .milliseconds(60))

    #expect(applied == [second])
    #expect(coordinator.phase == .applied)
}

@MainActor
@Test func configApplyCoordinatorFlushesWithoutWaitingForDebounce() async {
    let coordinator = ConfigApplyCoordinator(
        debounceDuration: .seconds(10),
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
        debounceDuration: .seconds(10),
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
        debounceDuration: .milliseconds(10),
        successDisplayDuration: .seconds(1)
    )
    var appliedNames: [String] = []
    var firstApplyStarted = false
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
        firstApplyStarted = true
        try? await Task.sleep(for: .milliseconds(40))
        return .saved
    }
    for _ in 0..<100 where !firstApplyStarted {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(firstApplyStarted)

    coordinator.schedule(second) { request in
        appliedNames.append(request.config.network_name)
        return .saved
    }

    for _ in 0..<100 where appliedNames.count < 2 {
        try await Task.sleep(for: .milliseconds(2))
    }

    #expect(appliedNames == ["first", "second"])
    #expect(coordinator.phase == .applied)
}
