import Foundation

struct RuntimeMemberStatusMetricsSnapshot: Equatable {
    var txBytes: Int64
    var rxBytes: Int64
    var latency: String
    var lossRate: String

    init(_ member: NetworkMemberStatus) {
        txBytes = member.txBytes
        rxBytes = member.rxBytes
        latency = member.latency
        lossRate = member.lossRate
    }

    func applied(to member: NetworkMemberStatus) -> NetworkMemberStatus {
        var updated = member
        updated.uploadTotal = txBytes > 0 ? ByteFormatter.format(txBytes) : "-"
        updated.downloadTotal = rxBytes > 0 ? ByteFormatter.format(rxBytes) : "-"
        updated.txBytes = txBytes
        updated.rxBytes = rxBytes
        updated.latency = latency
        updated.lossRate = lossRate
        return updated
    }
}

struct RuntimeTrafficCounter {
    var timestamp: Date
    var txBytes: Int64
    var rxBytes: Int64
}

struct RuntimePresentationState {
    var instances: [NetworkInstance] = []
    var runtimeDetails: [String: NetworkInstanceRunningInfo] = [:]
    var statusMetricsByInstance: [String: [String: RuntimeMemberStatusMetricsSnapshot]] = [:]
    var trafficSamplesByInstance: [String: [TrafficSample]] = [:]
    var trafficCountersByInstance: [String: RuntimeTrafficCounter] = [:]
}

struct RuntimePresentationChange {
    var state: RuntimePresentationState
    var shouldPublishInstances: Bool
    var shouldPublishRuntimeDetails: Bool
    var shouldPublishStatusMetrics: Bool
    var shouldPublishTrafficSamples: Bool
}

enum RuntimePresentationReducer {
    static let defaultTrafficSampleWindow = 60

    static func reduce(
        running: [NetworkInstance],
        previous: RuntimePresentationState,
        selectedTab: WorkspaceTab,
        now: Date = Date(),
        trafficSampleWindow: Int = Self.defaultTrafficSampleWindow
    ) -> RuntimePresentationChange {
        let newDetails = runtimeDetails(from: running)
        let nextRuntimeDetails = runtimeDetailsPresentationUnchanged(previous.runtimeDetails, newDetails)
            ? previous.runtimeDetails
            : newDetails

        let nextInstances = instancesStructureUnchanged(previous.instances, running)
            ? previous.instances
            : running

        let statusMetricsResult = statusMetrics(
            from: running,
            previous: previous.statusMetricsByInstance,
            isActive: selectedTab == .status
        )
        let trafficSamplesResult = trafficSamples(
            from: running,
            previousSamples: previous.trafficSamplesByInstance,
            previousCounters: previous.trafficCountersByInstance,
            isActive: selectedTab == .view,
            now: now,
            sampleWindow: trafficSampleWindow
        )

        return RuntimePresentationChange(
            state: RuntimePresentationState(
                instances: nextInstances,
                runtimeDetails: nextRuntimeDetails,
                statusMetricsByInstance: statusMetricsResult,
                trafficSamplesByInstance: trafficSamplesResult.samples,
                trafficCountersByInstance: trafficSamplesResult.counters
            ),
            shouldPublishInstances: nextInstances != previous.instances,
            shouldPublishRuntimeDetails: nextRuntimeDetails != previous.runtimeDetails,
            shouldPublishStatusMetrics: statusMetricsResult != previous.statusMetricsByInstance,
            shouldPublishTrafficSamples: trafficSamplesResult.samples != previous.trafficSamplesByInstance
        )
    }

    private static func runtimeDetails(from running: [NetworkInstance]) -> [String: NetworkInstanceRunningInfo] {
        var details: [String: NetworkInstanceRunningInfo] = [:]
        for instance in running {
            if let detail = instance.detail {
                details[instance.name] = detail
            }
        }
        return details
    }

    private static func statusMetrics(
        from running: [NetworkInstance],
        previous: [String: [String: RuntimeMemberStatusMetricsSnapshot]],
        isActive: Bool
    ) -> [String: [String: RuntimeMemberStatusMetricsSnapshot]] {
        guard isActive else { return previous }

        let activeNames = Set(running.map(\.name))
        var next = previous.filter { activeNames.contains($0.key) }

        for instance in running {
            guard let detail = instance.detail else { continue }
            next[instance.name] = Dictionary(
                uniqueKeysWithValues: detail.memberStatuses.map { member in
                    (member.id, RuntimeMemberStatusMetricsSnapshot(member))
                }
            )
        }

        return next
    }

    private static func trafficSamples(
        from running: [NetworkInstance],
        previousSamples: [String: [TrafficSample]],
        previousCounters: [String: RuntimeTrafficCounter],
        isActive: Bool,
        now: Date,
        sampleWindow: Int
    ) -> (samples: [String: [TrafficSample]], counters: [String: RuntimeTrafficCounter]) {
        guard isActive else { return (previousSamples, previousCounters) }

        let activeNames = Set(running.map(\.name))
        var nextSamples = previousSamples.filter { activeNames.contains($0.key) }
        var nextCounters = previousCounters.filter { activeNames.contains($0.key) }

        for instance in running {
            guard let detail = instance.detail else { continue }
            let totals = detail.trafficTotals
            let previous = nextCounters[instance.name]
            nextCounters[instance.name] = RuntimeTrafficCounter(
                timestamp: now,
                txBytes: totals.txBytes,
                rxBytes: totals.rxBytes
            )

            let sample: TrafficSample
            if let previous {
                let interval = max(now.timeIntervalSince(previous.timestamp), 0.001)
                let txDelta = max(0, totals.txBytes - previous.txBytes)
                let rxDelta = max(0, totals.rxBytes - previous.rxBytes)
                sample = TrafficSample(
                    timestamp: now,
                    txBytesPerSecond: Double(txDelta) / interval,
                    rxBytesPerSecond: Double(rxDelta) / interval
                )
            } else {
                sample = TrafficSample(timestamp: now, txBytesPerSecond: 0, rxBytesPerSecond: 0)
            }

            var samples = nextSamples[instance.name] ?? []
            samples.append(sample)
            if samples.count > sampleWindow {
                samples.removeFirst(samples.count - sampleWindow)
            }
            nextSamples[instance.name] = samples
        }

        return (nextSamples, nextCounters)
    }

    private static func instancesStructureUnchanged(_ current: [NetworkInstance], _ running: [NetworkInstance]) -> Bool {
        guard current.count == running.count else { return false }
        let currentByID = Dictionary(current.map { ($0.instance_id, $0) }, uniquingKeysWith: { $1 })
        for newInstance in running {
            guard let oldInstance = currentByID[newInstance.instance_id] else { return false }
            if oldInstance.name != newInstance.name { return false }
            if oldInstance.error_msg != newInstance.error_msg { return false }

            let oldMembers = oldInstance.detail?.memberStatuses ?? []
            let newMembers = newInstance.detail?.memberStatuses ?? []
            guard oldMembers.count == newMembers.count else { return false }
            for (old, new) in zip(oldMembers, newMembers) {
                if old.id != new.id { return false }
                if old.hostname != new.hostname { return false }
                if old.isLocal != new.isLocal { return false }
                if old.virtualIPv4 != new.virtualIPv4 { return false }
                if old.isPublicServer != new.isPublicServer { return false }
                if old.peerID != new.peerID { return false }
                if old.instanceID != new.instanceID { return false }
            }
        }
        return true
    }

    private static func runtimeDetailsPresentationUnchanged(
        _ current: [String: NetworkInstanceRunningInfo],
        _ newDetails: [String: NetworkInstanceRunningInfo]
    ) -> Bool {
        guard current.count == newDetails.count else { return false }
        for (name, newDetail) in newDetails {
            guard let currentDetail = current[name] else { return false }
            guard RuntimeDetailPresentationSignature(currentDetail) == RuntimeDetailPresentationSignature(newDetail) else {
                return false
            }
        }
        return true
    }
}

private struct RuntimeDetailPresentationSignature: Equatable {
    var devName: String?
    var running: Bool?
    var errorMessage: String?
    var instanceID: String?
    var localNode: RuntimeLocalNodeSignature?
    var memberStatuses: [RuntimeMemberSignature]
    var listenerErrorEvents: [String]
    var fullyConnectedWithoutRemoteExpectation: Bool
    var fullyConnectedWithRemoteExpectation: Bool

    init(_ detail: NetworkInstanceRunningInfo) {
        devName = detail.dev_name
        running = detail.running
        errorMessage = detail.error_msg
        instanceID = detail.instance_id
        localNode = detail.my_node_info.map(RuntimeLocalNodeSignature.init)
        memberStatuses = detail.memberStatuses.map(RuntimeMemberSignature.init)
        listenerErrorEvents = (detail.events ?? []).filter(Self.isPresentationRelevantEvent)
        fullyConnectedWithoutRemoteExpectation = detail.isFullyConnected(expectRemotePeers: false)
        fullyConnectedWithRemoteExpectation = detail.isFullyConnected(expectRemotePeers: true)
    }

    private static func isPresentationRelevantEvent(_ event: String) -> Bool {
        event.contains("ListenerAddFailed")
            || event.contains("ListenerAcceptFailed")
            || event.contains("TunDeviceError")
    }
}

private struct RuntimeLocalNodeSignature: Equatable {
    var peerID: Int?
    var displayIPv4: String
    var hostname: String?
    var udpNATType: Int?
    var isPublicServer: Bool

    init(_ node: NodeInfo) {
        peerID = node.peer_id
        displayIPv4 = node.displayIPv4
        hostname = node.hostname
        udpNATType = node.stun_info?.udp_nat_type
        isPublicServer = node.feature_flag?.is_public_server == true
    }
}

private struct RuntimeMemberSignature: Equatable {
    var id: String
    var isLocal: Bool
    var peerID: String
    var instanceID: String?
    var virtualIPv4: String
    var hostname: String
    var routeCost: String
    var tunnelProto: String
    var natType: String
    var isPublicServer: Bool

    init(_ member: NetworkMemberStatus) {
        id = member.id
        isLocal = member.isLocal
        peerID = member.peerID
        instanceID = member.instanceID
        virtualIPv4 = member.virtualIPv4
        hostname = member.hostname
        routeCost = member.routeCost
        tunnelProto = member.tunnelProto
        natType = member.natType
        isPublicServer = member.isPublicServer
    }
}
