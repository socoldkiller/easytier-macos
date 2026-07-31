import Foundation
import Testing
@testable import EasyTierShared

@Test func runtimeTrafficSnapshotPrecomputesDisplaySamples() throws {
    let config = NetworkConfig(instance_id: "traffic-id", network_name: "traffic-network")
    let instance = NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)
    let base = Date(timeIntervalSince1970: 1_000)
    let windowEnd = base.addingTimeInterval(60)
    let activeSessionID = UUID()
    let previousSessionID = UUID()
    let outsideWindow = TrafficSample(
        timestamp: base.addingTimeInterval(-1),
        txBytesPerSecond: 80,
        rxBytesPerSecond: 20,
        sessionID: previousSessionID
    )
    let activeLatest = TrafficSample(
        timestamp: base.addingTimeInterval(30),
        txBytesPerSecond: 90,
        rxBytesPerSecond: 40,
        sessionID: activeSessionID
    )
    let newerPreviousSession = TrafficSample(
        timestamp: base.addingTimeInterval(40),
        txBytesPerSecond: 100,
        rxBytesPerSecond: 30,
        sessionID: previousSessionID
    )
    let invalid = TrafficSample(
        timestamp: base.addingTimeInterval(50),
        txBytesPerSecond: .nan,
        rxBytesPerSecond: 50,
        sessionID: activeSessionID
    )
    let resumeEvent = TrafficResumeEvent(
        timestamp: base.addingTimeInterval(20),
        gapDuration: 10,
        reason: .gap
    )
    let samplingStatus = RuntimeTrafficSamplingStatus(
        activeSessionID: activeSessionID,
        phase: .live,
        resumeEvent: resumeEvent,
        lastObservedAt: windowEnd
    )

    let snapshot = RuntimeTrafficSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        samples: [newerPreviousSession, invalid, outsideWindow, activeLatest],
        samplingStatus: samplingStatus
    )

    #expect(snapshot.networkName == config.network_name)
    #expect(snapshot.samples.count == 4)
    #expect(snapshot.displaySamples.map(\.id) == [activeLatest.id, newerPreviousSession.id])
    #expect(snapshot.latest?.id == activeLatest.id)
    #expect(snapshot.maxValue == 200)
    #expect(snapshot.timeSpanLabel == "Live - Last 60 sec")
    #expect(snapshot.samplingPhase == .live)
    #expect(snapshot.activeSessionID == activeSessionID)
    #expect(snapshot.resumeEvent == resumeEvent)
    #expect(snapshot.windowStart == base)
    #expect(snapshot.windowEnd == windowEnd)
    #expect(snapshot.accessibilitySummary.contains("Upload"))
    #expect(snapshot.accessibilitySummary.contains("Download"))
}

@Test func collectingTrafficSnapshotDoesNotExposeAnOldSessionAsLatest() {
    let config = NetworkConfig(instance_id: "traffic-id", network_name: "traffic-network")
    let instance = NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)
    let now = Date(timeIntervalSince1970: 2_000)
    let activeSessionID = UUID()
    let oldSample = TrafficSample(
        timestamp: now.addingTimeInterval(-5),
        txBytesPerSecond: 1_024,
        rxBytesPerSecond: 2_048,
        sessionID: UUID()
    )
    let resumeEvent = TrafficResumeEvent(timestamp: now, gapDuration: 86_400, reason: .gap)
    let samplingStatus = RuntimeTrafficSamplingStatus(
        activeSessionID: activeSessionID,
        phase: .collecting,
        resumeEvent: resumeEvent,
        lastObservedAt: now
    )

    let snapshot = RuntimeTrafficSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        samples: [oldSample],
        samplingStatus: samplingStatus
    )

    #expect(snapshot.displaySamples.map(\.id) == [oldSample.id])
    #expect(snapshot.latest == nil)
    #expect(snapshot.samplingPhase == .collecting)
    #expect(snapshot.activeSessionID == activeSessionID)
    #expect(snapshot.resumeEvent == resumeEvent)
    #expect(snapshot.windowStart == now.addingTimeInterval(-60))
    #expect(snapshot.windowEnd == now)
    #expect(snapshot.timeSpanLabel == "Resuming after 1d pause...")
    #expect(snapshot.accessibilitySummary.contains("1 day"))
}

@Test func emptyRuntimeTrafficSnapshotWaitsWithoutAChartWindow() {
    #expect(RuntimeTrafficSnapshot.empty.samplingPhase == .waiting)
    #expect(RuntimeTrafficSnapshot.empty.activeSessionID == nil)
    #expect(RuntimeTrafficSnapshot.empty.windowStart == nil)
    #expect(RuntimeTrafficSnapshot.empty.windowEnd == nil)
    #expect(RuntimeTrafficSnapshot.empty.latest == nil)
}

@Test func runtimeStatusSnapshotKeepsTUNRuntimeStartingUntilVirtualIPv4Appears() {
    let config = NetworkConfig(instance_id: "dhcp-id", network_name: "dhcp-network")
    let startingDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: startingDetail
    )

    let starting = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: startingDetail,
        memberStatusMetricsByID: nil
    )

    #expect(instance.isFullyConnected)
    #expect(starting.runtimeReadinessPhase == .starting)
    #expect(!starting.isFullyConnected)

    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(
            virtual_ipv4: IPv4InetValue(rawValue: "10.0.64.1/24"),
            hostname: "local",
            peer_id: 7
        ),
        running: true,
        instance_id: config.instance_id
    )
    let ready = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: readyDetail,
        memberStatusMetricsByID: nil
    )

    #expect(ready.runtimeReadinessPhase == .ready)
    #expect(ready.isFullyConnected)
}

@Test func runtimeStatusSnapshotShowsAvailableTopologyWhileStaticTUNIsStarting() {
    let config = NetworkConfig(
        instance_id: "static-starting-id",
        dhcp: false,
        virtual_ipv4: "10.0.64.7",
        network_length: 24,
        network_name: "static-starting-network"
    )
    let detail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(hostname: "local", peer_id: 7),
        peer_route_pairs: [
            PeerRoutePair(
                route: Route(
                    peer_id: 8,
                    ipv4_addr: IPv4InetValue(rawValue: "10.0.64.8/24"),
                    cost: 1,
                    hostname: "peer"
                ),
                peer: PeerInfo(
                    peer_id: 8,
                    conns: [
                        PeerConnInfo(
                            conn_id: "peer-connection",
                            peer_id: 8,
                            tunnel: TunnelInfo(tunnel_type: "tcp")
                        ),
                    ]
                )
            ),
        ],
        running: true,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: detail
    )

    let snapshot = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: nil,
        memberStatusMetricsByID: nil
    )

    #expect(snapshot.runtimeReadinessPhase == .starting)
    #expect(snapshot.members.map(\.hostname) == ["local", "peer"])
    #expect(snapshot.members.first(where: \.isLocal)?.virtualIPv4 == "10.0.64.7/24")
}

@Test func runtimeStatusSnapshotDoesNotPresentConfiguredStaticIPv4AfterRuntimeFailure() throws {
    let config = NetworkConfig(
        instance_id: "failed-static-id",
        dhcp: false,
        virtual_ipv4: "10.0.64.7",
        network_length: 24,
        network_name: "failed-static-network"
    )
    let detail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(hostname: "local", peer_id: 7),
        running: false,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: detail
    )

    let snapshot = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: detail,
        memberStatusMetricsByID: nil
    )

    #expect(snapshot.runtimeReadinessPhase == .failed)
    let localMember = try #require(snapshot.members.first { $0.isLocal })
    #expect(localMember.copyableIPv4Address == nil)
}

@Test func runtimeStatusSnapshotTreatsNoTunRuntimeAsReadyWithoutVirtualIPv4() {
    let config = NetworkConfig(
        instance_id: "no-tun-id",
        network_name: "no-tun-network",
        no_tun: true
    )
    let detail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: detail
    )

    let snapshot = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: detail,
        memberStatusMetricsByID: nil
    )

    #expect(snapshot.runtimeReadinessPhase == .ready)
    #expect(snapshot.isFullyConnected)
}

@Test func runtimeStatusSnapshotReportsRuntimeFailureBeforeReadiness() {
    let config = NetworkConfig(instance_id: "failed-id", network_name: "failed-network")
    let detail = NetworkInstanceRunningInfo(
        events: [
            #"{"event":{"TunDeviceError":"permission denied"}}"#,
            #"{"event":{"TunDeviceReady":"utun8"}}"#,
        ],
        running: true,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: detail
    )

    let snapshot = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: detail,
        memberStatusMetricsByID: nil
    )

    #expect(snapshot.runtimeReadinessPhase == .failed)
    #expect(snapshot.runtimeError == "TUN device error: permission denied")
    #expect(!snapshot.isFullyConnected)

    let haltedDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: false,
        instance_id: config.instance_id
    )
    let halted = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: haltedDetail,
        memberStatusMetricsByID: nil
    )

    #expect(halted.runtimeReadinessPhase == .failed)
    #expect(halted.runtimeError == "EasyTier reported that this network stopped unexpectedly.")
    #expect(!halted.isFullyConnected)
}

@Test func runtimeStatusSnapshotIgnoresTunFailureSupersededByReadyEvent() {
    let config = NetworkConfig(instance_id: "recovered-tun-id", network_name: "recovered-tun-network")
    let detail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        events: [
            #"{"event":{"TunDeviceReady":"utun8"}}"#,
            #"{"event":{"TunDeviceError":"temporary failure"}}"#,
        ],
        running: true,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: detail
    )

    let snapshot = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: detail,
        memberStatusMetricsByID: nil
    )

    #expect(snapshot.runtimeReadinessPhase == .ready)
    #expect(snapshot.runtimeError == nil)
}

@Test func runtimeStatusSnapshotIgnoresListenerFailureSupersededByAddedEvent() {
    let config = NetworkConfig(
        instance_id: "recovered-listener-id",
        network_name: "recovered-listener-network",
        no_tun: true
    )
    let detail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(hostname: "local", peer_id: 7),
        events: [
            #"{"event":{"ListenerAdded":"tcp://0.0.0.0:54321"}}"#,
            #"{"event":{"ListenerAddFailed":["tcp://0.0.0.0:0","address in use"]}}"#,
        ],
        running: true,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: detail
    )

    let snapshot = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: detail,
        memberStatusMetricsByID: nil
    )

    #expect(snapshot.runtimeReadinessPhase == .ready)
    #expect(snapshot.runtimeError == nil)
}

@MainActor
@Test func runSelectedConfigRemainsStartingUntilTUNAddressAppears() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "dhcp-id", network_name: "dhcp-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(hostname: "local", peer_id: 7),
            running: true,
            instance_id: config.instance_id
        ),
    ]

    await store.runSelectedConfig()

    #expect(store.selectedConfigCanStop)
    #expect(store.selectedConfigIsRunning)
    #expect(!store.selectedConfigIsReady)
    #expect(store.selectedRuntimeReadinessPhase == .starting)

    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
            running: true,
            instance_id: config.instance_id
        ),
    ]
    await store.refreshRuntime()

    #expect(store.selectedConfigIsReady)
    #expect(store.selectedRuntimeReadinessPhase == .ready)
}

@MainActor
@Test func pauseThenRunRetainsMembersAndReplacesThemIncrementally() async throws {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "restart-id", network_name: "restart-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    let fullDetail = NetworkInstanceRunningInfo(
        dev_name: "utun-restart",
        my_node_info: NodeInfo(
            virtual_ipv4: IPv4InetValue(rawValue: "10.0.64.1/24"),
            hostname: "local",
            peer_id: 7
        ),
        peer_route_pairs: [
            PeerRoutePair(
                route: Route(
                    peer_id: 8,
                    ipv4_addr: IPv4InetValue(rawValue: "10.0.64.8/24"),
                    cost: 1,
                    hostname: "peer",
                    inst_id: "remote-instance"
                ),
                peer: PeerInfo(
                    peer_id: 8,
                    conns: [
                        PeerConnInfo(
                            conn_id: "remote-connection",
                            peer_id: 8,
                            tunnel: TunnelInfo(tunnel_type: "tcp")
                        ),
                    ]
                )
            ),
        ],
        running: true,
        instance_id: config.instance_id
    )

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    client.networkInfos = [config.network_name: fullDetail]

    await store.runSelectedConfig()

    #expect(store.selectedRuntimeReadinessPhase == .ready)
    #expect(store.selectedMemberStatuses.map(\.hostname) == ["local", "peer"])
    #expect(store.selectedMemberStatuses.allSatisfy { $0.isLive })

    client.networkInfos = [:]
    await store.stopSelectedConfig()

    #expect(store.selectedRuntimeReadinessPhase == .stopped)
    #expect(store.selectedMemberStatuses.isEmpty)

    await store.runSelectedConfig()

    #expect(store.selectedRuntimeReadinessPhase == .starting)
    #expect(store.selectedMemberStatuses.map(\.hostname) == ["local", "peer"])
    #expect(store.selectedMemberStatuses.first(where: { $0.isLocal })?.availability == .assigningAddress)
    #expect(store.selectedMemberStatuses.first(where: { !$0.isLocal })?.availability == .connecting)

    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(
            dev_name: "utun-restart",
            my_node_info: NodeInfo(hostname: "local", peer_id: 7),
            running: true,
            instance_id: config.instance_id
        ),
    ]
    await store.refreshRuntime()

    #expect(store.selectedMemberStatuses.count == 2)
    #expect(store.selectedMemberStatuses.first(where: { $0.isLocal })?.availability == .assigningAddress)
    #expect(store.selectedMemberStatuses.first(where: { !$0.isLocal })?.availability == .connecting)

    client.networkInfos = [config.network_name: fullDetail]
    await store.refreshRuntime()

    #expect(store.selectedRuntimeReadinessPhase == .ready)
    #expect(store.selectedMemberStatuses.map(\.hostname) == ["local", "peer"])
    #expect(store.selectedMemberStatuses.allSatisfy { $0.isLive })
}

@Test func runtimeStatusSnapshotAppliesMemberTrafficMetrics() throws {
    let config = NetworkConfig(instance_id: "status-id", network_name: "status-network")
    let detail = NetworkInstanceRunningInfo(
        dev_name: "utun9",
        my_node_info: NodeInfo(ipv4_addr: "10.0.0.1", hostname: "local-host", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true, detail: detail)
    let member = try #require(detail.memberStatuses.first)
    var trafficMember = member
    trafficMember.txBytes = 2_048
    trafficMember.rxBytes = 4_096

    let snapshot = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: detail,
        memberStatusMetricsByID: [member.id: RuntimeMemberStatusMetricsSnapshot(trafficMember)]
    )

    let displayedMember = try #require(snapshot.members.first)
    #expect(snapshot.networkName == config.network_name)
    #expect(snapshot.deviceName == "utun9")
    #expect(snapshot.isFullyConnected)
    #expect(displayedMember.txBytes == 2_048)
    #expect(displayedMember.rxBytes == 4_096)
    #expect(displayedMember.uploadTotal == ByteFormatter.format(2_048))
    #expect(displayedMember.downloadTotal == ByteFormatter.format(4_096))
}

@Test func runtimeStatusSnapshotAppliesMemberLatencyMetrics() throws {
    let config = NetworkConfig(instance_id: "status-id", network_name: "status-network")
    let detail = NetworkInstanceRunningInfo(
        dev_name: "utun9",
        peer_route_pairs: [
            PeerRoutePair(
                route: Route(
                    peer_id: 9,
                    ipv4_addr: IPv4InetValue(rawValue: "10.0.0.9/24"),
                    hostname: "remote"
                ),
                peer: PeerInfo(
                    peer_id: 9,
                    conns: [
                        PeerConnInfo(
                            peer_id: 9,
                            stats: PeerConnStats(latency_us: 1_000)
                        ),
                    ]
                )
            ),
        ],
        running: true,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true, detail: detail)
    let member = try #require(detail.memberStatuses.first)
    var metricMember = member
    metricMember.latency = "8 ms"

    let snapshot = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: detail,
        memberStatusMetricsByID: [member.id: RuntimeMemberStatusMetricsSnapshot(metricMember)]
    )

    let displayedMember = try #require(snapshot.members.first(where: { $0.id == member.id }))
    #expect(displayedMember.latency == "8 ms")
}
