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
        memberTrafficByID: [String: RuntimeMemberTrafficSnapshot]?
    ) -> RuntimeStatusSnapshot {
        guard let selectedConfig else { return .empty }

        var instance = runningInstance
        if let runtimeDetail {
            instance?.detail = runtimeDetail
        }

        let members = runtimeDetail?.memberStatuses ?? []
        let displayedMembers: [NetworkMemberStatus]
        if let memberTrafficByID {
            displayedMembers = members.map { member in
                memberTrafficByID[member.id]?.applied(to: member) ?? member
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
    public var maxValue: Double
    public var timeSpanLabel: String
    public var accessibilitySummary: String

    public static let empty = RuntimeTrafficSnapshot(
        instance: nil,
        networkName: "-",
        samples: [],
        displaySamples: [],
        latest: nil,
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
        samples: [TrafficSample]
    ) -> RuntimeTrafficSnapshot {
        guard let selectedConfig else { return .empty }

        let displaySamples = Self.displaySamples(from: samples)
        let latest = displaySamples.last

        return RuntimeTrafficSnapshot(
            instance: runningInstance,
            networkName: runningInstance?.name ?? selectedConfig.network_name.nilIfEmpty ?? "-",
            samples: samples,
            displaySamples: displaySamples,
            latest: latest,
            maxValue: Self.maxChartValue(for: displaySamples),
            timeSpanLabel: Self.timeSpanLabel(for: displaySamples),
            accessibilitySummary: Self.accessibilitySummary(for: latest)
        )
    }

    public static func axisValues(maxValue: Double) -> [Double] {
        (0...4).map { maxValue * Double($0) / 4 }
    }

    private static func displaySamples(from samples: [TrafficSample]) -> [TrafficSample] {
        samples
            .filter { sample in
                sample.timestamp.timeIntervalSinceReferenceDate.isFinite
                    && sample.txBytesPerSecond.isFinite
                    && sample.rxBytesPerSecond.isFinite
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private static func maxChartValue(for samples: [TrafficSample]) -> Double {
        let maxSampleValue = samples.lazy.flatMap { [$0.txBytesPerSecond, $0.rxBytesPerSecond] }.max() ?? 0
        return niceAxisMaximum(max(maxSampleValue, 16))
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

    private static func timeSpanLabel(for samples: [TrafficSample]) -> String {
        guard let first = samples.first?.timestamp, let last = samples.last?.timestamp else {
            return "Waiting for samples"
        }
        guard samples.count > 1 else {
            return "Collecting samples"
        }
        let seconds = max(0, last.timeIntervalSince(first))
        if seconds < 90 {
            return "Last \(Int(seconds.rounded())) sec"
        }
        return "Last \(String(format: "%.1f", seconds / 60)) min"
    }

    private static func accessibilitySummary(for latest: TrafficSample?) -> String {
        guard let latest else { return "No data yet" }
        let upload = ByteFormatter.formatRate(latest.txBytesPerSecond)
        let download = ByteFormatter.formatRate(latest.rxBytesPerSecond)
        return "Upload \(upload), Download \(download)"
    }
}
