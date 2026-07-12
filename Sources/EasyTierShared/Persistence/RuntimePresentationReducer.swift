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
    var sessionID: UUID
    var pendingResumeEvent: TrafficResumeEvent?
}

struct RuntimeTrafficSamplingStatus: Equatable {
    var activeSessionID: UUID
    var phase: TrafficSamplingPhase
    var resumeEvent: TrafficResumeEvent?
    var lastObservedAt: Date
}

struct RuntimePresentationState {
    var instances: [NetworkInstance] = []
    var runtimeDetails: [String: NetworkInstanceRunningInfo] = [:]
    var memberPresentation = RuntimeMemberPresentationState()
    var statusMetricsByInstance: [String: [String: RuntimeMemberStatusMetricsSnapshot]] = [:]
    var trafficSamplesByInstance: [String: [TrafficSample]] = [:]
    var trafficCountersByInstance: [String: RuntimeTrafficCounter] = [:]
    var trafficSamplingStatusByInstance: [String: RuntimeTrafficSamplingStatus] = [:]
}

struct RuntimeMemberPresentationState: Equatable {
    var lastKnownMembersByInstanceID: [String: [NetworkMemberStatus]] = [:]
    var visibleMembersByInstanceName: [String: [NetworkMemberStatus]] = [:]
}

struct RuntimePresentationChange {
    var state: RuntimePresentationState
    var shouldPublishInstances: Bool
    var shouldPublishRuntimeDetails: Bool
    var shouldPublishMemberPresentation: Bool
    var shouldPublishStatusMetrics: Bool
    var shouldPublishTrafficSamples: Bool
    var shouldPublishTrafficSamplingStatus: Bool
}

enum RuntimePresentationReducer {
    static let defaultTrafficSampleWindow = 60
    static let trafficSampleDuration: TimeInterval = 60
    static let trafficDiscontinuityThreshold: TimeInterval = 5

    static func reduce(
        running: [NetworkInstance],
        previous: RuntimePresentationState,
        selectedTab: WorkspaceTab,
        now: Date = Date(),
        trafficSampleWindow: Int = Self.defaultTrafficSampleWindow
    ) -> RuntimePresentationChange {
        let runningSnapshots = running.map(RuntimeInstancePresentationSnapshot.init)
        let newDetails = runtimeDetails(from: runningSnapshots)
        let runtimeDetailsUnchanged = runtimeDetailsPresentationUnchanged(previous.runtimeDetails, runningSnapshots)
        let nextRuntimeDetails = runtimeDetailsUnchanged
            ? previous.runtimeDetails
            : newDetails

        let instancesUnchanged = instancesStructureUnchanged(previous.instances, runningSnapshots)
        let nextInstances = instancesUnchanged
            ? previous.instances
            : running
        let nextMemberPresentation = memberPresentation(
            from: runningSnapshots,
            previous: previous.memberPresentation
        )

        let statusMetricsResult = statusMetrics(
            from: runningSnapshots,
            previous: previous.statusMetricsByInstance,
            isActive: selectedTab == .status
        )
        let trafficSamplesResult = trafficSamples(
            from: runningSnapshots,
            previousSamples: previous.trafficSamplesByInstance,
            previousCounters: previous.trafficCountersByInstance,
            previousStatuses: previous.trafficSamplingStatusByInstance,
            isActive: selectedTab == .view,
            now: now,
            sampleWindow: trafficSampleWindow
        )

        return RuntimePresentationChange(
            state: RuntimePresentationState(
                instances: nextInstances,
                runtimeDetails: nextRuntimeDetails,
                memberPresentation: nextMemberPresentation,
                statusMetricsByInstance: statusMetricsResult,
                trafficSamplesByInstance: trafficSamplesResult.samples,
                trafficCountersByInstance: trafficSamplesResult.counters,
                trafficSamplingStatusByInstance: trafficSamplesResult.statuses
            ),
            shouldPublishInstances: !instancesUnchanged,
            shouldPublishRuntimeDetails: !runtimeDetailsUnchanged,
            shouldPublishMemberPresentation: nextMemberPresentation != previous.memberPresentation,
            shouldPublishStatusMetrics: statusMetricsResult != previous.statusMetricsByInstance,
            shouldPublishTrafficSamples: trafficSamplesResult.samples != previous.trafficSamplesByInstance,
            shouldPublishTrafficSamplingStatus: trafficSamplesResult.statuses != previous.trafficSamplingStatusByInstance
        )
    }

    private static func runtimeDetails(from running: [RuntimeInstancePresentationSnapshot]) -> [String: NetworkInstanceRunningInfo] {
        var details: [String: NetworkInstanceRunningInfo] = [:]
        for snapshot in running {
            if let detail = snapshot.instance.detail {
                details[snapshot.instance.name] = detail
            }
        }
        return details
    }

    private static func memberPresentation(
        from running: [RuntimeInstancePresentationSnapshot],
        previous: RuntimeMemberPresentationState
    ) -> RuntimeMemberPresentationState {
        var next = previous
        next.visibleMembersByInstanceName = [:]

        for snapshot in running {
            let instance = snapshot.instance
            let liveMembers = snapshot.memberStatuses.map(markedOnline)
            let previousKnown = next.lastKnownMembersByInstanceID[instance.instance_id] ?? []
            let merged = mergeMembers(live: liveMembers, lastKnown: previousKnown)
            let canRetainMissingMembers = instance.running
                && instance.detail?.running != false
                && instance.runtimeErrorMessage == nil
                && instance.listenerErrorFromEvents == nil

            if !liveMembers.isEmpty {
                let shouldPreservePreviousMembers = canRetainMissingMembers
                    && instance.detail?.my_node_info == nil
                next.lastKnownMembersByInstanceID[instance.instance_id] = shouldPreservePreviousMembers
                    ? merged.lastKnown
                    : liveMembers
            }
            next.visibleMembersByInstanceName[instance.name] = canRetainMissingMembers
                ? merged.visible
                : liveMembers
        }

        return next
    }

    private static func mergeMembers(
        live: [NetworkMemberStatus],
        lastKnown: [NetworkMemberStatus]
    ) -> (visible: [NetworkMemberStatus], lastKnown: [NetworkMemberStatus]) {
        var liveByIdentity: [String: NetworkMemberStatus] = [:]
        var liveOrder: [String] = []
        for member in live {
            let identity = memberIdentity(member)
            if liveByIdentity[identity] == nil {
                liveOrder.append(identity)
            }
            liveByIdentity[identity] = member
        }

        var visible: [NetworkMemberStatus] = []
        var updatedKnown: [NetworkMemberStatus] = []
        var consumed = Set<String>()
        visible.reserveCapacity(max(live.count, lastKnown.count))
        updatedKnown.reserveCapacity(max(live.count, lastKnown.count))

        for knownMember in lastKnown {
            let identity = memberIdentity(knownMember)
            guard consumed.insert(identity).inserted else { continue }
            if let current = liveByIdentity[identity] {
                visible.append(current)
                updatedKnown.append(current)
            } else {
                let known = markedOnline(knownMember)
                visible.append(markedConnecting(known))
                updatedKnown.append(known)
            }
        }

        for identity in liveOrder where consumed.insert(identity).inserted {
            guard let current = liveByIdentity[identity] else { continue }
            visible.append(current)
            updatedKnown.append(current)
        }

        return (visible, updatedKnown)
    }

    private static func memberIdentity(_ member: NetworkMemberStatus) -> String {
        if member.isLocal { return "local" }
        if let instanceID = member.instanceID?.nilIfEmpty { return "instance:\(instanceID)" }
        if let peerID = member.peerID.nilIfEmpty, peerID != "-" { return "peer:\(peerID)" }
        return "member:\(member.id)"
    }

    private static func markedOnline(_ member: NetworkMemberStatus) -> NetworkMemberStatus {
        var member = member
        member.availability = .online
        // Dynamic counters are published through statusMetricsByInstance so
        // retained-member bookkeeping does not re-render the table every poll.
        member.latency = "-"
        member.uploadTotal = "-"
        member.downloadTotal = "-"
        member.lossRate = "-"
        member.txBytes = 0
        member.rxBytes = 0
        return member
    }

    private static func markedConnecting(_ member: NetworkMemberStatus) -> NetworkMemberStatus {
        var member = member
        member.availability = .connecting
        member.routeCost = "-"
        member.tunnelProto = "-"
        member.latency = "-"
        member.uploadTotal = "-"
        member.downloadTotal = "-"
        member.lossRate = "-"
        member.txBytes = 0
        member.rxBytes = 0
        return member
    }

    private static func statusMetrics(
        from running: [RuntimeInstancePresentationSnapshot],
        previous: [String: [String: RuntimeMemberStatusMetricsSnapshot]],
        isActive: Bool
    ) -> [String: [String: RuntimeMemberStatusMetricsSnapshot]] {
        guard isActive else { return previous }

        let activeNames = Set(running.map(\.instance.name))
        var next = previous.filter { activeNames.contains($0.key) }

        for snapshot in running {
            guard snapshot.instance.detail != nil else { continue }
            next[snapshot.instance.name] = Dictionary(
                uniqueKeysWithValues: snapshot.memberStatuses.map { member in
                    (member.id, RuntimeMemberStatusMetricsSnapshot(member))
                }
            )
        }

        return next
    }

    private static func trafficSamples(
        from running: [RuntimeInstancePresentationSnapshot],
        previousSamples: [String: [TrafficSample]],
        previousCounters: [String: RuntimeTrafficCounter],
        previousStatuses: [String: RuntimeTrafficSamplingStatus],
        isActive: Bool,
        now: Date,
        sampleWindow: Int
    ) -> (
        samples: [String: [TrafficSample]],
        counters: [String: RuntimeTrafficCounter],
        statuses: [String: RuntimeTrafficSamplingStatus]
    ) {
        guard isActive else { return (previousSamples, previousCounters, previousStatuses) }

        let activeNames = Set(running.map(\.instance.name))
        var nextSamples = previousSamples.filter { activeNames.contains($0.key) }
        var nextCounters = previousCounters.filter { activeNames.contains($0.key) }
        var nextStatuses = previousStatuses.filter { activeNames.contains($0.key) }
        let cutoff = now.addingTimeInterval(-trafficSampleDuration)

        for snapshot in running {
            guard snapshot.instance.detail != nil else { continue }
            let totals = snapshot.trafficTotals
            let instanceName = snapshot.instance.name
            let previous = nextCounters[instanceName]
            var samples = (nextSamples[instanceName] ?? []).filter { $0.timestamp >= cutoff }

            guard let previous else {
                let sessionID = UUID()
                let existingStatus = nextStatuses[instanceName]
                let resumeEvent: TrafficResumeEvent? = if existingStatus?.phase == .collecting {
                    existingStatus?.resumeEvent
                } else if !samples.isEmpty || existingStatus != nil {
                    TrafficResumeEvent(timestamp: now, reason: .counterReset)
                } else {
                    nil
                }
                nextCounters[instanceName] = RuntimeTrafficCounter(
                    timestamp: now,
                    txBytes: totals.txBytes,
                    rxBytes: totals.rxBytes,
                    sessionID: sessionID,
                    pendingResumeEvent: resumeEvent
                )
                nextStatuses[instanceName] = RuntimeTrafficSamplingStatus(
                    activeSessionID: sessionID,
                    phase: .collecting,
                    resumeEvent: resumeEvent,
                    lastObservedAt: now
                )
                store(trimmed(samples, limit: sampleWindow), for: instanceName, in: &nextSamples)
                continue
            }

            let interval = now.timeIntervalSince(previous.timestamp)
            let clockAdjusted = !interval.isFinite || interval <= 0
            let hasLongGap = interval > trafficDiscontinuityThreshold
            let counterReset = totals.txBytes < previous.txBytes || totals.rxBytes < previous.rxBytes

            if clockAdjusted || hasLongGap || counterReset {
                let reason: TrafficResumeReason
                let gapDuration: TimeInterval?
                if clockAdjusted {
                    reason = .clockAdjusted
                    gapDuration = nil
                    samples.removeAll()
                } else if hasLongGap {
                    reason = .gap
                    gapDuration = interval
                } else {
                    reason = .counterReset
                    gapDuration = nil
                }

                let sessionID = UUID()
                let resumeEvent = TrafficResumeEvent(timestamp: now, gapDuration: gapDuration, reason: reason)
                nextCounters[instanceName] = RuntimeTrafficCounter(
                    timestamp: now,
                    txBytes: totals.txBytes,
                    rxBytes: totals.rxBytes,
                    sessionID: sessionID,
                    pendingResumeEvent: resumeEvent
                )
                nextStatuses[instanceName] = RuntimeTrafficSamplingStatus(
                    activeSessionID: sessionID,
                    phase: .collecting,
                    resumeEvent: resumeEvent,
                    lastObservedAt: now
                )
                store(trimmed(samples, limit: sampleWindow), for: instanceName, in: &nextSamples)
                continue
            }

            let sample = TrafficSample(
                timestamp: now,
                txBytesPerSecond: Double(totals.txBytes - previous.txBytes) / interval,
                rxBytesPerSecond: Double(totals.rxBytes - previous.rxBytes) / interval,
                sessionID: previous.sessionID
            )
            samples.append(sample)
            let resumeEvent = previous.pendingResumeEvent ?? nextStatuses[instanceName]?.resumeEvent
            nextCounters[instanceName] = RuntimeTrafficCounter(
                timestamp: now,
                txBytes: totals.txBytes,
                rxBytes: totals.rxBytes,
                sessionID: previous.sessionID,
                pendingResumeEvent: nil
            )
            nextStatuses[instanceName] = RuntimeTrafficSamplingStatus(
                activeSessionID: previous.sessionID,
                phase: .live,
                resumeEvent: resumeEvent,
                lastObservedAt: now
            )
            store(trimmed(samples, limit: sampleWindow), for: instanceName, in: &nextSamples)
        }

        return (nextSamples, nextCounters, nextStatuses)
    }

    private static func trimmed(_ samples: [TrafficSample], limit: Int) -> [TrafficSample] {
        guard limit > 0, samples.count > limit else { return limit > 0 ? samples : [] }
        return Array(samples.suffix(limit))
    }

    private static func store(
        _ samples: [TrafficSample],
        for instanceName: String,
        in storage: inout [String: [TrafficSample]]
    ) {
        if samples.isEmpty {
            storage.removeValue(forKey: instanceName)
        } else {
            storage[instanceName] = samples
        }
    }

    private static func instancesStructureUnchanged(
        _ current: [NetworkInstance],
        _ running: [RuntimeInstancePresentationSnapshot]
    ) -> Bool {
        guard current.count == running.count else { return false }
        let currentByID = Dictionary(current.map { ($0.instance_id, $0) }, uniquingKeysWith: { $1 })
        for snapshot in running {
            let newInstance = snapshot.instance
            guard let oldInstance = currentByID[newInstance.instance_id] else { return false }
            if oldInstance.name != newInstance.name { return false }
            if oldInstance.error_msg != newInstance.error_msg { return false }

            let oldMembers = oldInstance.detail?.memberStatuses ?? []
            let newMembers = snapshot.memberStatuses
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
        _ running: [RuntimeInstancePresentationSnapshot]
    ) -> Bool {
        let detailsCount = running.reduce(into: 0) { count, snapshot in
            if snapshot.instance.detail != nil { count += 1 }
        }
        guard current.count == detailsCount else { return false }
        for snapshot in running {
            guard let newDetail = snapshot.instance.detail else { continue }
            guard let currentDetail = current[snapshot.instance.name] else { return false }
            guard RuntimeDetailPresentationSignature(currentDetail) == RuntimeDetailPresentationSignature(newDetail, memberStatuses: snapshot.memberStatuses) else {
                return false
            }
        }
        return true
    }
}

private struct RuntimeInstancePresentationSnapshot {
    var instance: NetworkInstance
    var memberStatuses: [NetworkMemberStatus]
    var trafficTotals: (txBytes: Int64, rxBytes: Int64)

    init(instance: NetworkInstance) {
        self.instance = instance
        memberStatuses = instance.detail?.memberStatuses ?? []
        trafficTotals = instance.detail?.trafficTotals ?? (txBytes: 0, rxBytes: 0)
    }
}

private struct RuntimeDetailPresentationSignature: Equatable {
    var devName: String?
    var running: Bool?
    var errorMessage: String?
    var instanceID: String?
    var localNode: RuntimeLocalNodeSignature?
    var memberStatuses: [RuntimeMemberSignature]
    var readinessEvents: [String]
    var fullyConnectedWithoutRemoteExpectation: Bool
    var fullyConnectedWithRemoteExpectation: Bool

    init(_ detail: NetworkInstanceRunningInfo, memberStatuses: [NetworkMemberStatus]? = nil) {
        devName = detail.dev_name
        running = detail.running
        errorMessage = detail.error_msg
        instanceID = detail.instance_id
        localNode = detail.my_node_info.map(RuntimeLocalNodeSignature.init)
        self.memberStatuses = (memberStatuses ?? detail.memberStatuses).map(RuntimeMemberSignature.init)
        readinessEvents = (detail.events ?? []).filter(Self.isPresentationRelevantEvent)
        fullyConnectedWithoutRemoteExpectation = detail.isFullyConnected(expectRemotePeers: false)
        fullyConnectedWithRemoteExpectation = detail.isFullyConnected(expectRemotePeers: true)
    }

    private static func isPresentationRelevantEvent(_ event: String) -> Bool {
        event.contains("ListenerAddFailed")
            || event.contains("ListenerAcceptFailed")
            || event.contains("ListenerAdded")
            || event.contains("TunDeviceError")
            || event.contains("TunDeviceReady")
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
