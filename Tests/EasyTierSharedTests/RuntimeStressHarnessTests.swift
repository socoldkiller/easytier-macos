import Foundation
import Testing
@testable import EasyTierShared

@MainActor
@Test func compressedRuntimePollingLoopFeedsLargeRuntimeSnapshots() async {
    let profile = RuntimeStressProfile(instanceCount: 2, peersPerInstance: 40, iterations: 120)
    let client = RuntimeStressClient(profile: profile)
    let store = EasyTierAppStore(client: client)
    RuntimeStressHarness.seed(store, profile: profile)
    store.selectedTab = .view

    let result = await RuntimeStressHarness.runCompressedPollingLoop(
        store: store,
        client: client,
        profile: profile
    )

    #expect(result.iterations == profile.iterations)
    #expect(result.collectCount == profile.iterations)
    #expect(result.instanceCount == profile.instanceCount)
    #expect(result.selectedMemberCount == profile.peersPerInstance + 1)
    #expect(result.selectedTrafficSampleCount == 60)
    #expect(result.elapsedSeconds < 5)
}

@MainActor
@Test func compressedRuntimePollingLoopCanYieldBetweenPolls() async {
    let profile = RuntimeStressProfile(
        instanceCount: 1,
        peersPerInstance: 10,
        iterations: 12,
        pollDelay: .milliseconds(1)
    )
    let client = RuntimeStressClient(profile: profile)
    let store = EasyTierAppStore(client: client)
    RuntimeStressHarness.seed(store, profile: profile)
    store.selectedTab = .view

    let result = await RuntimeStressHarness.runCompressedPollingLoop(
        store: store,
        client: client,
        profile: profile
    )

    #expect(result.collectCount == profile.iterations)
    #expect(result.instanceCount == 1)
    #expect(result.selectedMemberCount == 11)
    #expect(result.selectedTrafficSampleCount == 12)
}

@MainActor
@Test func runtimeDetailsNotReassignedWhenDataUnchanged() async {
    let profile = RuntimeStressProfile(instanceCount: 1, peersPerInstance: 5, iterations: 50)
    let client = StaticRuntimeClient(profile: profile)
    let store = EasyTierAppStore(client: client)
    RuntimeStressHarness.seed(store, profile: profile)
    store.resetWriteCounters()

    let result = await RuntimeStressHarness.runCompressedPollingLoop(
        store: store,
        client: client,
        profile: profile
    )

    #expect(result.collectCount == profile.iterations)
    #expect(
        result.runtimeDetailsWrites == 1,
        "runtimeDetails should publish once for identical runtime data, got \(result.runtimeDetailsWrites)/\(profile.iterations)."
    )
}

@MainActor
@Test func runtimeDetailsBaselineStillReassignedEveryPollWhenStatsChange() async {
    let profile = RuntimeStressProfile(instanceCount: 1, peersPerInstance: 5, iterations: 50)
    let client = RuntimeStressClient(profile: profile)
    let store = EasyTierAppStore(client: client)
    RuntimeStressHarness.seed(store, profile: profile)
    store.resetWriteCounters()

    let result = await RuntimeStressHarness.runCompressedPollingLoop(
        store: store,
        client: client,
        profile: profile
    )

    #expect(
        result.runtimeDetailsWrites == 1,
        "runtimeDetails should not republish for traffic/stat-only runtime changes, got \(result.runtimeDetailsWrites)/\(profile.iterations)."
    )
}

@MainActor
@Test func trafficSamplesSkippedWhenNotOnTrafficTab() async {
    let profile = RuntimeStressProfile(instanceCount: 1, peersPerInstance: 3, iterations: 20)
    let client = RuntimeStressClient(profile: profile)
    let store = EasyTierAppStore(client: client)
    RuntimeStressHarness.seed(store, profile: profile)
    store.selectedTab = .status
    store.resetWriteCounters()

    let result = await RuntimeStressHarness.runCompressedPollingLoop(
        store: store,
        client: client,
        profile: profile
    )

    #expect(
        result.trafficSamplesWrites == 0,
        "trafficSamplesByInstance should not be written while the traffic tab is inactive, got \(result.trafficSamplesWrites)/\(profile.iterations) on .status."
    )

    store.selectedTab = .view
    store.resetWriteCounters()
    let result2 = await RuntimeStressHarness.runCompressedPollingLoop(
        store: store,
        client: client,
        profile: profile
    )

    #expect(
        result2.trafficSamplesWrites > 0,
        "trafficSamplesByInstance should be written when on the traffic tab, got \(result2.trafficSamplesWrites)"
    )
}

@MainActor
@Test func isConfigServerConnectedStableWhenUnchanged() async {
    let profile = RuntimeStressProfile(instanceCount: 1, peersPerInstance: 3, iterations: 30)
    let client = StableConfigServerClient(profile: profile)
    let store = EasyTierAppStore(client: client)
    RuntimeStressHarness.seed(store, profile: profile)
    store.mode = .default
    store.resetWriteCounters()

    let result = await RuntimeStressHarness.runCompressedPollingLoop(
        store: store,
        client: client,
        profile: profile
    )

    #expect(
        result.isConfigServerConnectedWrites <= 1,
        "isConfigServerConnected should only publish when its value changes, got \(result.isConfigServerConnectedWrites)/\(profile.iterations)."
    )
}

@MainActor
@Test func instancesNotReassignedWhenOnlyStatsChange() async {
    let profile = RuntimeStressProfile(instanceCount: 1, peersPerInstance: 5, iterations: 50)
    let client = RuntimeStressClient(profile: profile)
    let store = EasyTierAppStore(client: client)
    RuntimeStressHarness.seed(store, profile: profile)
    store.resetWriteCounters()

    let result = await RuntimeStressHarness.runCompressedPollingLoop(
        store: store,
        client: client,
        profile: profile
    )

    #expect(
        result.instancesWrites == 1,
        "instances has structural diff (hostname/ipv4 only); stats changes should NOT reassign it. got \(result.instancesWrites)/\(profile.iterations)"
    )
}

private struct RuntimeStressProfile: Sendable {
    var instanceCount: Int
    var peersPerInstance: Int
    var iterations: Int
    var pollDelay: Duration?

    init(
        instanceCount: Int,
        peersPerInstance: Int,
        iterations: Int,
        pollDelay: Duration? = nil
    ) {
        self.instanceCount = max(1, instanceCount)
        self.peersPerInstance = max(0, peersPerInstance)
        self.iterations = max(1, iterations)
        self.pollDelay = pollDelay
    }

    func networkName(for index: Int) -> String {
        "stress-network-\(index + 1)"
    }

    func instanceID(for index: Int) -> String {
        "stress-instance-\(index + 1)"
    }
}

private struct RuntimeStressResult: Sendable {
    var iterations: Int
    var elapsedSeconds: TimeInterval
    var instanceCount: Int
    var selectedMemberCount: Int
    var selectedTrafficSampleCount: Int
    var collectCount: Int
    var runtimeDetailsWrites: Int
    var instancesWrites: Int
    var trafficSamplesWrites: Int
    var isConfigServerConnectedWrites: Int
}

private enum RuntimeStressHarness {
    @MainActor
    static func seed(_ store: EasyTierAppStore, profile: RuntimeStressProfile) {
        store.configs = (0..<profile.instanceCount).map { index in
            StoredNetworkConfig(config: NetworkConfig(
                instance_id: profile.instanceID(for: index),
                network_name: profile.networkName(for: index)
            ))
        }
        store.selectedConfigID = store.configs.first?.id
        store.selectedTab = .status
    }

    @MainActor
    static func runCompressedPollingLoop(
        store: EasyTierAppStore,
        client: RuntimePollingClient,
        profile: RuntimeStressProfile
    ) async -> RuntimeStressResult {
        let startedAt = Date()
        for _ in 0..<profile.iterations {
            await store.refreshRuntime()
            if let delay = profile.pollDelay {
                try? await Task.sleep(for: delay)
            }
        }

        return RuntimeStressResult(
            iterations: profile.iterations,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            instanceCount: store.instances.count,
            selectedMemberCount: store.selectedMemberStatuses.count,
            selectedTrafficSampleCount: store.selectedTrafficSamples.count,
            collectCount: client.collectCount,
            runtimeDetailsWrites: store.runtimeDetailsWriteCount,
            instancesWrites: store.instancesWriteCount,
            trafficSamplesWrites: store.trafficSamplesByInstanceWriteCount,
            isConfigServerConnectedWrites: store.isConfigServerConnectedWriteCount
        )
    }
}

private protocol RuntimePollingClient: EasyTierCoreClient {
    var collectCount: Int { get }
}

extension RuntimeStressClient: RuntimePollingClient {}
extension StaticRuntimeClient: RuntimePollingClient {}

private final class RuntimeStressClient: EasyTierCoreClient, @unchecked Sendable {
    private let profile: RuntimeStressProfile
    private let lock = NSLock()
    private var tick = 0

    init(profile: RuntimeStressProfile) {
        self.profile = profile
    }

    var collectCount: Int {
        lock.withLock { tick }
    }

    func version() async throws -> String { "stress" }
    func validate(toml _: String) async throws {}
    func run(config _: NetworkConfig) async throws {}
    func run(toml _: String) async throws {}
    func stop(instanceNames _: [String]) async throws {}
    func retain(instanceNames _: [String]) async throws {}
    func listInstances() async throws -> [NetworkInstance] { [] }

    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] {
        let nextTick = lock.withLock {
            tick += 1
            return tick
        }

        return Dictionary(uniqueKeysWithValues: (0..<profile.instanceCount).map { instanceIndex in
            (profile.networkName(for: instanceIndex), networkInfo(instanceIndex: instanceIndex, tick: nextTick))
        })
    }

    func configureRPCPortal(_ rpcPortal: String?, whitelist _: [String]?) async throws {
        if rpcPortal != nil { throw EasyTierCoreError.operationFailed("stress client does not expose RPC portal") }
    }

    func callJSONRPC(service _: String, method _: String, domain _: String?, payload _: String) async throws -> String {
        #"{"ok":true}"#
    }

    func connectRPCClient(clientID _: String, url _: URL) async throws {}
    func disconnectRPCClient(clientID _: String) async throws {}
    func startConfigServerClient(url _: URL) async throws {}
    func stopConfigServerClient() async throws {}
    func isConfigServerClientConnected() async throws -> Bool { true }

    private func networkInfo(instanceIndex: Int, tick: Int) -> NetworkInstanceRunningInfo {
        NetworkInstanceRunningInfo(
            dev_name: "utun-stress-\(instanceIndex)",
            my_node_info: NodeInfo(
                ipv4_addr: "10.\(144 + instanceIndex).0.1",
                virtual_ipv4: IPv4InetValue(rawValue: "10.\(144 + instanceIndex).0.1/24"),
                hostname: "stress-local-\(instanceIndex + 1)",
                version: "stress-\(tick)",
                peer_id: 10_000 + instanceIndex,
                stun_info: StunInfo(udp_nat_type: 1, tcp_nat_type: 1),
                feature_flag: PeerFeatureFlag(is_public_server: false)
            ),
            events: ["stress tick \(tick)"],
            peer_route_pairs: (0..<profile.peersPerInstance).map { peerIndex in
                peerRoutePair(instanceIndex: instanceIndex, peerIndex: peerIndex, tick: tick)
            },
            running: true,
            instance_id: profile.instanceID(for: instanceIndex)
        )
    }

    private func peerRoutePair(instanceIndex: Int, peerIndex: Int, tick: Int) -> PeerRoutePair {
        let peerID = 100_000 + instanceIndex * 10_000 + peerIndex
        let connID = "stress-\(instanceIndex)-\(peerIndex)"
        let txBytes = tick * 10_000 + peerIndex * 257
        let rxBytes = tick * 12_000 + peerIndex * 311
        let routeCost = peerIndex % 9 == 0 ? 2 : 1

        return PeerRoutePair(
            route: Route(
                peer_id: peerID,
                ipv4_addr: IPv4InetValue(rawValue: "10.\(instanceIndex + 1).\(peerIndex / 250).\(peerIndex % 250 + 2)/24"),
                next_hop_peer_id: routeCost == 1 ? peerID : peerID - 1,
                cost: routeCost,
                proxy_cidrs: ["172.\(instanceIndex).\(peerIndex % 255).0/24"],
                hostname: "stress-peer-\(instanceIndex + 1)-\(peerIndex + 1)",
                stun_info: StunInfo(udp_nat_type: peerIndex % 4, tcp_nat_type: peerIndex % 3),
                inst_id: "stress-remote-\(instanceIndex + 1)-\(peerIndex + 1)",
                version: "stress-\(tick)",
                feature_flag: PeerFeatureFlag(is_public_server: peerIndex == 0)
            ),
            peer: PeerInfo(
                peer_id: peerID,
                conns: [
                    PeerConnInfo(
                        conn_id: connID,
                        my_peer_id: 10_000 + instanceIndex,
                        is_client: peerIndex % 2 == 0,
                        peer_id: peerID,
                        features: ["stress"],
                        tunnel: TunnelInfo(
                            tunnel_type: peerIndex % 3 == 0 ? "tcp" : "udp",
                            local_addr: nil,
                            remote_addr: nil
                        ),
                        loss_rate: Double(peerIndex % 5) / 100.0,
                        stats: PeerConnStats(
                            rx_bytes: rxBytes,
                            tx_bytes: txBytes,
                            rx_packets: rxBytes / 1200,
                            tx_packets: txBytes / 1200,
                            latency_us: 1_000 + peerIndex * 150
                        )
                    ),
                ],
                default_conn_id: connID
            )
        )
    }
}

private class StaticRuntimeClient: EasyTierCoreClient, @unchecked Sendable {
    private let profile: RuntimeStressProfile
    private let lock = NSLock()
    private var tick = 0
    private lazy var snapshot: [String: NetworkInstanceRunningInfo] = {
        Dictionary(uniqueKeysWithValues: (0..<profile.instanceCount).map { index in
            (profile.networkName(for: index), Self.makeInfo(profile: profile, instanceIndex: index))
        })
    }()

    init(profile: RuntimeStressProfile) {
        self.profile = profile
    }

    var collectCount: Int {
        lock.withLock { tick }
    }

    func version() async throws -> String { "static" }
    func validate(toml _: String) async throws {}
    func run(config _: NetworkConfig) async throws {}
    func run(toml _: String) async throws {}
    func stop(instanceNames _: [String]) async throws {}
    func retain(instanceNames _: [String]) async throws {}
    func listInstances() async throws -> [NetworkInstance] { [] }

    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] {
        lock.withLock { tick += 1 }
        return snapshot
    }

    func configureRPCPortal(_ rpcPortal: String?, whitelist _: [String]?) async throws {
        if rpcPortal != nil { throw EasyTierCoreError.operationFailed("static client does not expose RPC portal") }
    }

    func callJSONRPC(service _: String, method _: String, domain _: String?, payload _: String) async throws -> String {
        #"{"ok":true}"#
    }

    func connectRPCClient(clientID _: String, url _: URL) async throws {}
    func disconnectRPCClient(clientID _: String) async throws {}
    func startConfigServerClient(url _: URL) async throws {}
    func stopConfigServerClient() async throws {}
    func isConfigServerClientConnected() async throws -> Bool { true }

    private static func makeInfo(profile: RuntimeStressProfile, instanceIndex: Int) -> NetworkInstanceRunningInfo {
        NetworkInstanceRunningInfo(
            dev_name: "utun-static-\(instanceIndex)",
            my_node_info: NodeInfo(
                ipv4_addr: "10.\(144 + instanceIndex).0.1",
                virtual_ipv4: IPv4InetValue(rawValue: "10.\(144 + instanceIndex).0.1/24"),
                hostname: "static-local-\(instanceIndex + 1)",
                version: "static",
                peer_id: 10_000 + instanceIndex,
                stun_info: StunInfo(udp_nat_type: 1, tcp_nat_type: 1),
                feature_flag: PeerFeatureFlag(is_public_server: false)
            ),
            events: ["static"],
            peer_route_pairs: (0..<profile.peersPerInstance).map { peerIndex in
                PeerRoutePair(
                    route: Route(
                        peer_id: 100_000 + instanceIndex * 10_000 + peerIndex,
                        ipv4_addr: IPv4InetValue(rawValue: "10.\(instanceIndex + 1).\(peerIndex / 250).\(peerIndex % 250 + 2)/24"),
                        next_hop_peer_id: 100_000 + instanceIndex * 10_000 + peerIndex,
                        cost: peerIndex % 9 == 0 ? 2 : 1,
                        proxy_cidrs: ["172.\(instanceIndex).\(peerIndex % 255).0/24"],
                        hostname: "static-peer-\(instanceIndex + 1)-\(peerIndex + 1)",
                        stun_info: StunInfo(udp_nat_type: peerIndex % 4, tcp_nat_type: peerIndex % 3),
                        inst_id: "static-remote-\(instanceIndex + 1)-\(peerIndex + 1)",
                        version: "static",
                        feature_flag: PeerFeatureFlag(is_public_server: peerIndex == 0)
                    ),
                    peer: PeerInfo(
                        peer_id: 100_000 + instanceIndex * 10_000 + peerIndex,
                        conns: [
                            PeerConnInfo(
                                conn_id: "static-\(instanceIndex)-\(peerIndex)",
                                my_peer_id: 10_000 + instanceIndex,
                                is_client: peerIndex % 2 == 0,
                                peer_id: 100_000 + instanceIndex * 10_000 + peerIndex,
                                features: ["static"],
                                tunnel: TunnelInfo(
                                    tunnel_type: peerIndex % 3 == 0 ? "tcp" : "udp",
                                    local_addr: nil,
                                    remote_addr: nil
                                ),
                                loss_rate: Double(peerIndex % 5) / 100.0,
                                stats: PeerConnStats(
                                    rx_bytes: 1_000_000 + peerIndex * 257,
                                    tx_bytes: 2_000_000 + peerIndex * 311,
                                    rx_packets: 800,
                                    tx_packets: 1600,
                                    latency_us: 1_000 + peerIndex * 150
                                )
                            ),
                        ],
                        default_conn_id: "static-\(instanceIndex)-\(peerIndex)"
                    )
                )
            },
            running: true,
            instance_id: profile.instanceID(for: instanceIndex)
        )
    }
}

private final class StableConfigServerClient: StaticRuntimeClient, @unchecked Sendable {
    override func isConfigServerClientConnected() async throws -> Bool { true }
}
