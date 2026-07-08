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

@Test func trafficTabRecordsSamplesOnlyWhenActive() {
    let inactive = RuntimePresentationReducer.reduce(
        running: [RuntimePresentationFixture.instance(txBytes: 10_000, rxBytes: 12_000)],
        previous: RuntimePresentationState(),
        selectedTab: .status,
        now: RuntimePresentationFixture.t0
    )

    #expect(!inactive.shouldPublishTrafficSamples)
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

    #expect(first.shouldPublishTrafficSamples)
    #expect(first.state.trafficSamplesByInstance["fixture-network"]?.count == 1)
    #expect(second.shouldPublishTrafficSamples)
    #expect(second.state.trafficSamplesByInstance["fixture-network"]?.count == 2)
    #expect(second.state.trafficSamplesByInstance["fixture-network"]?.last?.txBytesPerSecond == 5_000)
    #expect(second.state.trafficSamplesByInstance["fixture-network"]?.last?.rxBytesPerSecond == 6_000)
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

private enum RuntimePresentationFixture {
    static let t0 = Date(timeIntervalSince1970: 1_000)
    static let t1 = Date(timeIntervalSince1970: 1_001)

    static func instance(
        hostname: String = "peer-a",
        txBytes: Int,
        rxBytes: Int,
        latencyUs: Int = 1_000
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
