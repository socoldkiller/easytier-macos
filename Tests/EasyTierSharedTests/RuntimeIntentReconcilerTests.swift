import Foundation
import Testing
@testable import EasyTierShared

@Test func runtimeIntentReconcilerChoosesApplyAppliedAndConflict() {
    let intent = testIntent(base: "base", desired: " desired ")

    #expect(RuntimeIntentReconciler.reconciliation(
        for: intent,
        observation: testObservation(hostname: "base"),
        force: false
    ) == .apply(hostname: "desired"))
    #expect(RuntimeIntentReconciler.reconciliation(
        for: intent,
        observation: testObservation(hostname: "desired"),
        force: false
    ) == .applied)
    #expect(RuntimeIntentReconciler.reconciliation(
        for: intent,
        observation: testObservation(hostname: "third-party"),
        force: false
    ) == .conflict(current: "third-party", base: "base"))
}

@Test func runtimeIntentReconcilerForceOverridesConflict() {
    var intent = testIntent(base: "base", desired: "desired")
    intent.status = .conflict

    #expect(RuntimeIntentReconciler.reconciliation(
        for: intent,
        observation: testObservation(hostname: "third-party"),
        force: false
    ) == .ignore)
    #expect(RuntimeIntentReconciler.reconciliation(
        for: intent,
        observation: testObservation(hostname: "third-party"),
        force: true
    ) == .apply(hostname: "desired"))
}

@Test func runtimeIntentReconcilerUpsertPreservesStableIdentity() {
    let original = testIntent(id: "stable", base: "old", desired: "first")
    var intents = [original]
    let replacement = testIntent(id: "new", base: "old", desired: "second")

    let resolved = RuntimeIntentReconciler.upsert(replacement, in: &intents)

    #expect(intents.count == 1)
    #expect(resolved.id == "stable")
    #expect(intents[0].desiredHostname == "second")
}

@Test func runtimeIntentReconcilerExpiresTerminalIntentsAndCapsHistory() {
    let now = Date()
    var intents = [
        testIntent(id: "expired-applied", status: .applied, updatedAt: now.addingTimeInterval(-301)),
        testIntent(id: "expired-unreachable", status: .unreachable, updatedAt: now.addingTimeInterval(-601)),
        testIntent(id: "pending", status: .pending, updatedAt: now),
        testIntent(id: "recent-applied", status: .applied, updatedAt: now),
    ]

    #expect(RuntimeIntentReconciler.removeExpired(from: &intents, now: now, maximumCount: 2))
    #expect(intents.map(\.id) == ["pending", "recent-applied"])
}

private func testIntent(
    id: String = "intent",
    base: String? = "base",
    desired: String = "desired",
    status: RuntimeIntentStatus = .pending,
    updatedAt: Date = Date()
) -> RuntimeIntent {
    RuntimeIntent(
        id: id,
        target: RuntimeIntentTarget(
            networkName: "office",
            instanceID: "instance",
            isLocal: true
        ),
        desiredHostname: desired,
        baseHostname: base,
        status: status,
        updatedAt: updatedAt
    )
}

private func testObservation(hostname: String?) -> RuntimeIntentObservation {
    RuntimeIntentObservation(
        instanceID: "instance",
        hostname: hostname,
        ipv4: "10.1.1.2",
        rpcURL: URL(string: "tcp://10.1.1.2:15888"),
        label: "office"
    )
}
