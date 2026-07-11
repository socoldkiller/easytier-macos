import Foundation
import Testing
@testable import EasyTierShared

@Test func statsOnlyChangePublishesStatusMetricsOnlyOnStatusTab() {
    let first = RuntimePresentationReducer.reduce(
        running: [RuntimePresentationFixture.instance(txBytes: 10_000, rxBytes: 12_000)],
        previous: RuntimePresentationState(),
        selectedTab: .status,
        now: RuntimePresentationFixture.t0
    )

    let second = RuntimePresentationReducer.reduce(
        running: [RuntimePresentationFixture.instance(txBytes: 50_000, rxBytes: 60_000)],
        previous: first.state,
        selectedTab: .status,
        now: RuntimePresentationFixture.t1
    )

    #expect(!second.shouldPublishInstances)
    #expect(!second.shouldPublishRuntimeDetails)
    #expect(second.shouldPublishStatusMetrics)
    #expect(!second.shouldPublishTrafficSamples)
    #expect(second.state.statusMetricsByInstance["fixture-network"]?["peer-200"]?.txBytes == 50_000)
    #expect(second.state.statusMetricsByInstance["fixture-network"]?["peer-200"]?.rxBytes == 60_000)
}

@Test func latencyOnlyChangePublishesStatusMetricsOnlyOnStatusTab() {
    let first = RuntimePresentationReducer.reduce(
        running: [RuntimePresentationFixture.instance(txBytes: 10_000, rxBytes: 12_000, latencyUs: 1_000)],
        previous: RuntimePresentationState(),
        selectedTab: .status,
        now: RuntimePresentationFixture.t0
    )

    let second = RuntimePresentationReducer.reduce(
        running: [RuntimePresentationFixture.instance(txBytes: 10_000, rxBytes: 12_000, latencyUs: 8_000)],
        previous: first.state,
        selectedTab: .status,
        now: RuntimePresentationFixture.t1
    )

    #expect(!second.shouldPublishInstances)
    #expect(!second.shouldPublishRuntimeDetails)
    #expect(second.shouldPublishStatusMetrics)
    #expect(!second.shouldPublishTrafficSamples)
    #expect(second.state.statusMetricsByInstance["fixture-network"]?["peer-200"]?.latency == "8 ms")
}

@Test func inactiveStatusTabDoesNotPublishStatusMetrics() {
    let first = RuntimePresentationReducer.reduce(
        running: [RuntimePresentationFixture.instance(txBytes: 10_000, rxBytes: 12_000)],
        previous: RuntimePresentationState(),
        selectedTab: .status,
        now: RuntimePresentationFixture.t0
    )

    let second = RuntimePresentationReducer.reduce(
        running: [RuntimePresentationFixture.instance(txBytes: 50_000, rxBytes: 60_000)],
        previous: first.state,
        selectedTab: .config,
        now: RuntimePresentationFixture.t1
    )

    #expect(!second.shouldPublishInstances)
    #expect(!second.shouldPublishRuntimeDetails)
    #expect(!second.shouldPublishStatusMetrics)
    #expect(second.state.statusMetricsByInstance["fixture-network"]?["peer-200"]?.txBytes == 10_000)
}

@Test func unchangedStatusMetricsDoNotPublish() {
    let first = RuntimePresentationReducer.reduce(
        running: [RuntimePresentationFixture.instance(txBytes: 10_000, rxBytes: 12_000)],
        previous: RuntimePresentationState(),
        selectedTab: .status,
        now: RuntimePresentationFixture.t0
    )

    let second = RuntimePresentationReducer.reduce(
        running: [RuntimePresentationFixture.instance(txBytes: 10_000, rxBytes: 12_000)],
        previous: first.state,
        selectedTab: .status,
        now: RuntimePresentationFixture.t1
    )

    #expect(!second.shouldPublishInstances)
    #expect(!second.shouldPublishRuntimeDetails)
    #expect(!second.shouldPublishStatusMetrics)
    #expect(!second.shouldPublishTrafficSamples)
}

@Test func trafficTabEstablishesBaselineBeforeRecordingSamples() {
    let inactive = RuntimePresentationReducer.reduce(
        running: [RuntimePresentationFixture.instance(txBytes: 10_000, rxBytes: 12_000)],
        previous: RuntimePresentationState(),
        selectedTab: .status,
        now: RuntimePresentationFixture.t0
    )

    #expect(!inactive.shouldPublishTrafficSamples)
    #expect(!inactive.shouldPublishTrafficSamplingStatus)
    #expect(inactive.state.trafficSamplesByInstance.isEmpty)

    let first = RuntimePresentationReducer.reduce(
        running: [RuntimePresentationFixture.instance(txBytes: 10_000, rxBytes: 12_000)],
        previous: inactive.state,
        selectedTab: .view,
        now: RuntimePresentationFixture.t0
    )
    let second = RuntimePresentationReducer.reduce(
        running: [RuntimePresentationFixture.instance(txBytes: 15_000, rxBytes: 18_000)],
        previous: first.state,
        selectedTab: .view,
        now: RuntimePresentationFixture.t1
    )

    #expect(!first.shouldPublishTrafficSamples)
    #expect(first.shouldPublishTrafficSamplingStatus)
    #expect((first.state.trafficSamplesByInstance["fixture-network"] ?? []).isEmpty)
    #expect(first.state.trafficCountersByInstance["fixture-network"]?.txBytes == 10_000)
    #expect(first.state.trafficSamplingStatusByInstance["fixture-network"]?.phase == .collecting)
    #expect(second.shouldPublishTrafficSamples)
    #expect(second.shouldPublishTrafficSamplingStatus)
    #expect(second.state.trafficSamplesByInstance["fixture-network"]?.count == 1)
    #expect(second.state.trafficSamplesByInstance["fixture-network"]?.last?.txBytesPerSecond == 5_000)
    #expect(second.state.trafficSamplesByInstance["fixture-network"]?.last?.rxBytesPerSecond == 6_000)
    #expect(second.state.trafficSamplesByInstance["fixture-network"]?.last?.sessionID != TrafficSample.legacySessionID)
    #expect(second.state.trafficSamplingStatusByInstance["fixture-network"]?.phase == .live)
}

@Test func shortTrafficGapContinuesTheActiveSession() throws {
    let baseline = RuntimePresentationFixture.reduce(at: 0, txBytes: 10_000, rxBytes: 12_000)
    let first = RuntimePresentationFixture.reduce(
        previous: baseline.state,
        at: 1,
        txBytes: 15_000,
        rxBytes: 18_000
    )
    let afterThreeSeconds = RuntimePresentationFixture.reduce(
        previous: first.state,
        at: 4,
        txBytes: 21_000,
        rxBytes: 27_000
    )

    let samples = try #require(afterThreeSeconds.state.trafficSamplesByInstance["fixture-network"])
    #expect(samples.count == 2)
    #expect(samples[0].sessionID == samples[1].sessionID)
    #expect(samples[1].txBytesPerSecond == 2_000)
    #expect(samples[1].rxBytesPerSecond == 3_000)
    #expect(afterThreeSeconds.state.trafficSamplingStatusByInstance["fixture-network"]?.phase == .live)
    #expect(afterThreeSeconds.state.trafficSamplingStatusByInstance["fixture-network"]?.resumeEvent == nil)
}

@Test func longTrafficGapStartsANewSessionWithoutCrossGapRate() throws {
    let baseline = RuntimePresentationFixture.reduce(at: 0, txBytes: 10_000, rxBytes: 12_000)
    let first = RuntimePresentationFixture.reduce(
        previous: baseline.state,
        at: 1,
        txBytes: 15_000,
        rxBytes: 18_000
    )
    let originalSample = try #require(first.state.trafficSamplesByInstance["fixture-network"]?.first)
    let resumed = RuntimePresentationFixture.reduce(
        previous: first.state,
        at: 11,
        txBytes: 115_000,
        rxBytes: 218_000
    )

    let samplesAtResume = try #require(resumed.state.trafficSamplesByInstance["fixture-network"])
    let resumedStatus = try #require(resumed.state.trafficSamplingStatusByInstance["fixture-network"])
    #expect(samplesAtResume.map(\.id) == [originalSample.id])
    #expect(resumedStatus.activeSessionID != originalSample.sessionID)
    #expect(resumedStatus.phase == .collecting)
    #expect(resumedStatus.resumeEvent?.timestamp == RuntimePresentationFixture.date(at: 11))
    #expect(resumedStatus.resumeEvent?.gapDuration == 10)
    #expect(resumedStatus.resumeEvent?.reason == .gap)

    let next = RuntimePresentationFixture.reduce(
        previous: resumed.state,
        at: 12,
        txBytes: 116_000,
        rxBytes: 220_000
    )
    let samplesAfterResume = try #require(next.state.trafficSamplesByInstance["fixture-network"])
    let liveStatus = try #require(next.state.trafficSamplingStatusByInstance["fixture-network"])
    #expect(samplesAfterResume.count == 2)
    #expect(samplesAfterResume.last?.sessionID == resumedStatus.activeSessionID)
    #expect(samplesAfterResume.last?.txBytesPerSecond == 1_000)
    #expect(samplesAfterResume.last?.rxBytesPerSecond == 2_000)
    #expect(liveStatus.phase == .live)
    #expect(liveStatus.resumeEvent == resumedStatus.resumeEvent)
}

@Test func dayLongTrafficGapDropsExpiredSamplesAndWaitsForFreshRate() throws {
    let baseline = RuntimePresentationFixture.reduce(at: 0, txBytes: 10_000, rxBytes: 12_000)
    let first = RuntimePresentationFixture.reduce(
        previous: baseline.state,
        at: 1,
        txBytes: 15_000,
        rxBytes: 18_000
    )
    let originalSessionID = try #require(first.state.trafficSamplesByInstance["fixture-network"]?.first?.sessionID)
    let resumed = RuntimePresentationFixture.reduce(
        previous: first.state,
        at: 86_401,
        txBytes: 5_015_000,
        rxBytes: 6_018_000
    )

    #expect((resumed.state.trafficSamplesByInstance["fixture-network"] ?? []).isEmpty)
    #expect(resumed.state.trafficSamplingStatusByInstance["fixture-network"]?.activeSessionID != originalSessionID)
    #expect(resumed.state.trafficSamplingStatusByInstance["fixture-network"]?.phase == .collecting)
    #expect(resumed.state.trafficSamplingStatusByInstance["fixture-network"]?.resumeEvent?.gapDuration == 86_400)
    #expect(resumed.state.trafficSamplingStatusByInstance["fixture-network"]?.resumeEvent?.reason == .gap)

    let next = RuntimePresentationFixture.reduce(
        previous: resumed.state,
        at: 86_402,
        txBytes: 5_016_000,
        rxBytes: 6_020_000
    )
    let freshSample = try #require(next.state.trafficSamplesByInstance["fixture-network"]?.first)
    #expect(freshSample.sessionID != originalSessionID)
    #expect(freshSample.txBytesPerSecond == 1_000)
    #expect(freshSample.rxBytesPerSecond == 2_000)
}

@Test func wakeRestartPreservesTheOriginalGapResumeEvent() throws {
    let baseline = RuntimePresentationFixture.reduce(at: 0, txBytes: 10_000, rxBytes: 12_000)
    let first = RuntimePresentationFixture.reduce(
        previous: baseline.state,
        at: 1,
        txBytes: 15_000,
        rxBytes: 18_000
    )
    let resumed = RuntimePresentationFixture.reduce(
        previous: first.state,
        at: 86_401,
        txBytes: 5_015_000,
        rxBytes: 6_018_000
    )
    let gapEvent = try #require(resumed.state.trafficSamplingStatusByInstance["fixture-network"]?.resumeEvent)
    var afterRestart = resumed.state
    afterRestart.trafficCountersByInstance.removeValue(forKey: "fixture-network")

    let restartedBaseline = RuntimePresentationFixture.reduce(
        previous: afterRestart,
        at: 86_402,
        txBytes: 500,
        rxBytes: 800
    )
    let restartedStatus = try #require(restartedBaseline.state.trafficSamplingStatusByInstance["fixture-network"])

    #expect(restartedStatus.phase == .collecting)
    #expect(restartedStatus.resumeEvent == gapEvent)

    let fresh = RuntimePresentationFixture.reduce(
        previous: restartedBaseline.state,
        at: 86_403,
        txBytes: 1_500,
        rxBytes: 2_800
    )
    let freshStatus = try #require(fresh.state.trafficSamplingStatusByInstance["fixture-network"])
    #expect(freshStatus.phase == .live)
    #expect(freshStatus.resumeEvent == gapEvent)
    #expect(fresh.state.trafficSamplesByInstance["fixture-network"]?.last?.txBytesPerSecond == 1_000)
    #expect(fresh.state.trafficSamplesByInstance["fixture-network"]?.last?.rxBytesPerSecond == 2_000)
}

@Test func counterResetStartsANewTrafficSession() throws {
    let baseline = RuntimePresentationFixture.reduce(at: 0, txBytes: 10_000, rxBytes: 12_000)
    let first = RuntimePresentationFixture.reduce(
        previous: baseline.state,
        at: 1,
        txBytes: 15_000,
        rxBytes: 18_000
    )
    let originalSample = try #require(first.state.trafficSamplesByInstance["fixture-network"]?.first)
    let reset = RuntimePresentationFixture.reduce(
        previous: first.state,
        at: 2,
        txBytes: 500,
        rxBytes: 800
    )

    let resetStatus = try #require(reset.state.trafficSamplingStatusByInstance["fixture-network"])
    #expect(reset.state.trafficSamplesByInstance["fixture-network"]?.map(\.id) == [originalSample.id])
    #expect(resetStatus.activeSessionID != originalSample.sessionID)
    #expect(resetStatus.phase == .collecting)
    #expect(resetStatus.resumeEvent?.reason == .counterReset)
    #expect(resetStatus.resumeEvent?.gapDuration == nil)

    let next = RuntimePresentationFixture.reduce(
        previous: reset.state,
        at: 3,
        txBytes: 1_500,
        rxBytes: 2_800
    )
    #expect(next.state.trafficSamplesByInstance["fixture-network"]?.last?.sessionID == resetStatus.activeSessionID)
    #expect(next.state.trafficSamplesByInstance["fixture-network"]?.last?.txBytesPerSecond == 1_000)
    #expect(next.state.trafficSamplesByInstance["fixture-network"]?.last?.rxBytesPerSecond == 2_000)
}

@Test func clockMovingBackwardStartsANewTrafficSession() throws {
    let baseline = RuntimePresentationFixture.reduce(at: 0, txBytes: 10_000, rxBytes: 12_000)
    let first = RuntimePresentationFixture.reduce(
        previous: baseline.state,
        at: 1,
        txBytes: 15_000,
        rxBytes: 18_000
    )
    let originalSample = try #require(first.state.trafficSamplesByInstance["fixture-network"]?.first)
    let adjusted = RuntimePresentationFixture.reduce(
        previous: first.state,
        at: 0.5,
        txBytes: 16_000,
        rxBytes: 20_000
    )

    let adjustedStatus = try #require(adjusted.state.trafficSamplingStatusByInstance["fixture-network"])
    #expect((adjusted.state.trafficSamplesByInstance["fixture-network"] ?? []).isEmpty)
    #expect(adjustedStatus.activeSessionID != originalSample.sessionID)
    #expect(adjustedStatus.phase == .collecting)
    #expect(adjustedStatus.resumeEvent?.reason == .clockAdjusted)
    #expect(adjustedStatus.resumeEvent?.gapDuration == nil)
}

@Test func trafficSamplesAreTrimmedToTheLastSixtySeconds() throws {
    var change = RuntimePresentationFixture.reduce(at: 0, txBytes: 0, rxBytes: 0)

    for second in stride(from: 4, through: 68, by: 4) {
        change = RuntimePresentationFixture.reduce(
            previous: change.state,
            at: TimeInterval(second),
            txBytes: second * 1_000,
            rxBytes: second * 2_000
        )
    }

    let samples = try #require(change.state.trafficSamplesByInstance["fixture-network"])
    let cutoff = RuntimePresentationFixture.date(at: 8)
    #expect(samples.count == 16)
    #expect(samples.first?.timestamp == cutoff)
    #expect(samples.allSatisfy { $0.timestamp >= cutoff })
}

@Test func trafficSamplesKeepAHardMaximumOfSixtyPoints() throws {
    var change = RuntimePresentationFixture.reduce(at: 0, txBytes: 0, rxBytes: 0)

    for index in 1...61 {
        change = RuntimePresentationFixture.reduce(
            previous: change.state,
            at: Double(index) / 2,
            txBytes: index * 500,
            rxBytes: index * 1_000
        )
    }

    let samples = try #require(change.state.trafficSamplesByInstance["fixture-network"])
    #expect(samples.count == 60)
    #expect(samples.first?.timestamp == RuntimePresentationFixture.date(at: 1))
    #expect(samples.last?.timestamp == RuntimePresentationFixture.date(at: 30.5))
}

@Test func topologyChangePublishesTopologyWithoutRequiringMetricChange() {
    let first = RuntimePresentationReducer.reduce(
        running: [RuntimePresentationFixture.instance(hostname: "peer-a", txBytes: 10_000, rxBytes: 12_000)],
        previous: RuntimePresentationState(),
        selectedTab: .status,
        now: RuntimePresentationFixture.t0
    )

    let second = RuntimePresentationReducer.reduce(
        running: [RuntimePresentationFixture.instance(hostname: "peer-b", txBytes: 10_000, rxBytes: 12_000)],
        previous: first.state,
        selectedTab: .status,
        now: RuntimePresentationFixture.t1
    )

    #expect(second.shouldPublishInstances)
    #expect(second.shouldPublishRuntimeDetails)
    #expect(!second.shouldPublishStatusMetrics)
}

@Test func readinessRecoveryEventPublishesRuntimeDetails() {
    let failureEvent = #"{"event":{"TunDeviceError":"temporary failure"}}"#
    let readyEvent = #"{"event":{"TunDeviceReady":"utun8"}}"#
    let first = RuntimePresentationReducer.reduce(
        running: [RuntimePresentationFixture.instance(txBytes: 10_000, rxBytes: 12_000, events: [failureEvent])],
        previous: RuntimePresentationState(),
        selectedTab: .status,
        now: RuntimePresentationFixture.t0
    )

    let second = RuntimePresentationReducer.reduce(
        running: [RuntimePresentationFixture.instance(txBytes: 10_000, rxBytes: 12_000, events: [readyEvent, failureEvent])],
        previous: first.state,
        selectedTab: .status,
        now: RuntimePresentationFixture.t1
    )

    #expect(second.shouldPublishRuntimeDetails)
    #expect(second.state.runtimeDetails["fixture-network"]?.events == [readyEvent, failureEvent])
}

private enum RuntimePresentationFixture {
    static let t0 = Date(timeIntervalSince1970: 1_000)
    static let t1 = Date(timeIntervalSince1970: 1_001)

    static func date(at offset: TimeInterval) -> Date {
        t0.addingTimeInterval(offset)
    }

    static func reduce(
        previous: RuntimePresentationState = RuntimePresentationState(),
        at offset: TimeInterval,
        txBytes: Int,
        rxBytes: Int
    ) -> RuntimePresentationChange {
        RuntimePresentationReducer.reduce(
            running: [instance(txBytes: txBytes, rxBytes: rxBytes)],
            previous: previous,
            selectedTab: .view,
            now: date(at: offset)
        )
    }

    static func instance(
        hostname: String = "peer-a",
        txBytes: Int,
        rxBytes: Int,
        latencyUs: Int = 1_000,
        events: [String]? = nil
    ) -> NetworkInstance {
        NetworkInstance(
            instance_id: "fixture-instance",
            name: "fixture-network",
            running: true,
            detail: NetworkInstanceRunningInfo(
                dev_name: "utun-fixture",
                my_node_info: NodeInfo(
                    virtual_ipv4: IPv4InetValue(rawValue: "10.0.0.1/24"),
                    hostname: "local",
                    version: "fixture",
                    peer_id: 100,
                    stun_info: StunInfo(udp_nat_type: 1),
                    feature_flag: PeerFeatureFlag(is_public_server: false)
                ),
                events: events,
                peer_route_pairs: [
                    PeerRoutePair(
                        route: Route(
                            peer_id: 200,
                            ipv4_addr: IPv4InetValue(rawValue: "10.0.0.2/24"),
                            next_hop_peer_id: 200,
                            cost: 1,
                            hostname: hostname,
                            stun_info: StunInfo(udp_nat_type: 2),
                            inst_id: "remote-instance",
                            version: "fixture",
                            feature_flag: PeerFeatureFlag(is_public_server: false)
                        ),
                        peer: PeerInfo(
                            peer_id: 200,
                            conns: [
                                PeerConnInfo(
                                    conn_id: "conn",
                                    peer_id: 200,
                                    tunnel: TunnelInfo(tunnel_type: "udp"),
                                    stats: PeerConnStats(
                                        rx_bytes: rxBytes,
                                        tx_bytes: txBytes,
                                        rx_packets: rxBytes / 1200,
                                        tx_packets: txBytes / 1200,
                                        latency_us: latencyUs
                                    )
                                ),
                            ],
                            default_conn_id: "conn"
                        )
                    ),
                ],
                running: true,
                instance_id: "fixture-instance"
            )
        )
    }
}
