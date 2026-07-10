import Foundation

public struct RuntimeStatusSnapshot: Equatable, Sendable {
    public var instance: NetworkInstance?
    public var runtimeDetail: NetworkInstanceRunningInfo?
    public var networkName: String
    public var deviceName: String
    public var members: [NetworkMemberStatus]
    public var runtimeError: String?
    public var isFullyConnected: Bool

    public static let empty = RuntimeStatusSnapshot(
        instance: nil,
        runtimeDetail: nil,
        networkName: "-",
        deviceName: "-",
        members: [],
        runtimeError: nil,
        isFullyConnected: false
    )

    public var hasRunningInstance: Bool {
        instance != nil
    }

    static func build(
        selectedConfig: NetworkConfig?,
        runningInstance: NetworkInstance?,
        runtimeDetail: NetworkInstanceRunningInfo?,
        memberStatusMetricsByID: [String: RuntimeMemberStatusMetricsSnapshot]?
    ) -> RuntimeStatusSnapshot {
        guard let selectedConfig else { return .empty }

        var instance = runningInstance
        if let runtimeDetail {
            instance?.detail = runtimeDetail
        }

        let members = runtimeDetail?.memberStatuses ?? []
        let displayedMembers: [NetworkMemberStatus]
        if let memberStatusMetricsByID {
            displayedMembers = members.map { member in
                memberStatusMetricsByID[member.id]?.applied(to: member) ?? member
            }
        } else {
            displayedMembers = members
        }

        let isFullyConnected = instance?.isFullyConnected(
            expectRemotePeers: selectedConfig.expectsRemotePeerConnection
        ) == true

        return RuntimeStatusSnapshot(
            instance: instance,
            runtimeDetail: runtimeDetail,
            networkName: instance?.name ?? selectedConfig.network_name.nilIfEmpty ?? "-",
            deviceName: runtimeDetail?.dev_name ?? instance?.detail?.dev_name ?? "-",
            members: displayedMembers,
            runtimeError: instance?.runtimeErrorMessage ?? instance?.listenerErrorFromEvents,
            isFullyConnected: isFullyConnected
        )
    }
}

public struct RuntimeTrafficSnapshot: Equatable, Sendable {
    public var instance: NetworkInstance?
    public var networkName: String
    public var samples: [TrafficSample]
    public var displaySamples: [TrafficSample]
    public var latest: TrafficSample?
    public var samplingPhase: TrafficSamplingPhase
    public var activeSessionID: UUID?
    public var resumeEvent: TrafficResumeEvent?
    public var windowStart: Date?
    public var windowEnd: Date?
    public var maxValue: Double
    public var timeSpanLabel: String
    public var accessibilitySummary: String

    public static let empty = RuntimeTrafficSnapshot(
        instance: nil,
        networkName: "-",
        samples: [],
        displaySamples: [],
        latest: nil,
        samplingPhase: .waiting,
        activeSessionID: nil,
        resumeEvent: nil,
        windowStart: nil,
        windowEnd: nil,
        maxValue: 16,
        timeSpanLabel: "Waiting for samples",
        accessibilitySummary: "No data yet"
    )

    public var hasRunningInstance: Bool {
        instance != nil
    }

    static func build(
        selectedConfig: NetworkConfig?,
        runningInstance: NetworkInstance?,
        samples: [TrafficSample],
        samplingStatus: RuntimeTrafficSamplingStatus? = nil
    ) -> RuntimeTrafficSnapshot {
        guard let selectedConfig else { return .empty }
        guard let runningInstance else {
            return RuntimeTrafficSnapshot(
                instance: nil,
                networkName: selectedConfig.network_name.nilIfEmpty ?? "-",
                samples: samples,
                displaySamples: [],
                latest: nil,
                samplingPhase: .waiting,
                activeSessionID: nil,
                resumeEvent: nil,
                windowStart: nil,
                windowEnd: nil,
                maxValue: 16,
                timeSpanLabel: "Waiting for samples",
                accessibilitySummary: "No traffic data yet"
            )
        }

        let sortedSamples = Self.validSamples(from: samples)
        let activeSessionID = samplingStatus?.activeSessionID ?? sortedSamples.last?.sessionID
        let samplingPhase = samplingStatus?.phase ?? (sortedSamples.isEmpty ? .collecting : .live)
        let windowEnd = samplingStatus?.lastObservedAt ?? sortedSamples.last?.timestamp
        let windowStart = windowEnd?.addingTimeInterval(-RuntimePresentationReducer.trafficSampleDuration)
        let displaySamples = Self.displaySamples(
            from: sortedSamples,
            windowStart: windowStart,
            windowEnd: windowEnd
        )
        let latest = activeSessionID.flatMap { sessionID in
            displaySamples.last { $0.sessionID == sessionID }
        }
        let resumeEvent = samplingStatus?.resumeEvent

        return RuntimeTrafficSnapshot(
            instance: runningInstance,
            networkName: runningInstance.name,
            samples: samples,
            displaySamples: displaySamples,
            latest: latest,
            samplingPhase: samplingPhase,
            activeSessionID: activeSessionID,
            resumeEvent: resumeEvent,
            windowStart: windowStart,
            windowEnd: windowEnd,
            maxValue: Self.maxChartValue(for: displaySamples),
            timeSpanLabel: Self.timeSpanLabel(
                phase: samplingPhase,
                resumeEvent: resumeEvent,
                referenceDate: windowEnd
            ),
            accessibilitySummary: Self.accessibilitySummary(
                latest: latest,
                phase: samplingPhase,
                resumeEvent: resumeEvent,
                windowStart: windowStart
            )
        )
    }

    public static func axisValues(maxValue: Double) -> [Double] {
        (0...4).map { maxValue * Double($0) / 4 }
    }

    private static func validSamples(from samples: [TrafficSample]) -> [TrafficSample] {
        samples
            .filter { sample in
                sample.timestamp.timeIntervalSinceReferenceDate.isFinite
                    && sample.txBytesPerSecond.isFinite
                    && sample.rxBytesPerSecond.isFinite
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private static func displaySamples(
        from samples: [TrafficSample],
        windowStart: Date?,
        windowEnd: Date?
    ) -> [TrafficSample] {
        guard let windowStart, let windowEnd else { return samples }
        return samples.filter { $0.timestamp >= windowStart && $0.timestamp <= windowEnd }
    }

    private static func maxChartValue(for samples: [TrafficSample]) -> Double {
        let maxSampleValue = samples.lazy.flatMap { [$0.txBytesPerSecond, $0.rxBytesPerSecond] }.max() ?? 0
        return niceAxisMaximum(max(maxSampleValue * 1.12, 16))
    }

    private static func niceAxisMaximum(_ value: Double) -> Double {
        let exponent = floor(log10(value))
        let scale = pow(10, exponent)
        let normalized = value / scale
        let niceNormalized: Double
        if normalized <= 1 {
            niceNormalized = 1
        } else if normalized <= 2 {
            niceNormalized = 2
        } else if normalized <= 5 {
            niceNormalized = 5
        } else {
            niceNormalized = 10
        }
        return niceNormalized * scale
    }

    private static func timeSpanLabel(
        phase: TrafficSamplingPhase,
        resumeEvent: TrafficResumeEvent?,
        referenceDate: Date?
    ) -> String {
        switch phase {
        case .waiting:
            return "Waiting for samples"
        case .collecting:
            guard let resumeEvent else { return "Collecting new samples..." }
            if let gapDuration = resumeEvent.gapDuration {
                return "Resuming after \(compactDuration(gapDuration)) pause..."
            }
            return "Restarting sampling..."
        case .live:
            guard let resumeEvent,
                  let referenceDate,
                  referenceDate.timeIntervalSince(resumeEvent.timestamp) <= 8
            else {
                return "Live - Last 60 sec"
            }
            if let gapDuration = resumeEvent.gapDuration {
                return "Live - Resumed after \(compactDuration(gapDuration)) pause"
            }
            return "Live - Sampling restarted"
        }
    }

    private static func accessibilitySummary(
        latest: TrafficSample?,
        phase: TrafficSamplingPhase,
        resumeEvent: TrafficResumeEvent?,
        windowStart: Date?
    ) -> String {
        guard phase != .waiting else { return "No traffic data yet" }
        guard let latest else {
            if let gapDuration = resumeEvent?.gapDuration {
                return "Collecting new traffic samples after a \(spokenDuration(gapDuration)) pause"
            }
            return "Collecting new traffic samples"
        }
        let upload = ByteFormatter.formatRate(latest.txBytesPerSecond)
        let download = ByteFormatter.formatRate(latest.rxBytesPerSecond)
        var summary = "Traffic over the last 60 seconds. Upload \(upload), Download \(download)"
        if let resumeEvent,
           windowStart.map({ resumeEvent.timestamp >= $0 }) ?? false
        {
            if let gapDuration = resumeEvent.gapDuration {
                summary += ". Sampling resumed after a \(spokenDuration(gapDuration)) pause"
            } else {
                summary += ". Sampling restarted"
            }
        }
        return summary
    }

    private static func compactDuration(_ duration: TimeInterval) -> String {
        let duration = max(0, duration)
        if duration < 60 {
            return "\(max(1, Int(duration.rounded())))s"
        }
        if duration < 3_600 {
            return "\(max(1, Int((duration / 60).rounded())))m"
        }
        if duration < 86_400 {
            return "\(max(1, Int((duration / 3_600).rounded())))h"
        }
        return "\(max(1, Int((duration / 86_400).rounded())))d"
    }

    private static func spokenDuration(_ duration: TimeInterval) -> String {
        let duration = max(0, duration)
        if duration < 60 {
            let value = max(1, Int(duration.rounded()))
            return "\(value) second\(value == 1 ? "" : "s")"
        }
        if duration < 3_600 {
            let value = max(1, Int((duration / 60).rounded()))
            return "\(value) minute\(value == 1 ? "" : "s")"
        }
        if duration < 86_400 {
            let value = max(1, Int((duration / 3_600).rounded()))
            return "\(value) hour\(value == 1 ? "" : "s")"
        }
        let value = max(1, Int((duration / 86_400).rounded()))
        return "\(value) day\(value == 1 ? "" : "s")"
    }
}
