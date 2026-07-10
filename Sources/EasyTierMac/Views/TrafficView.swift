import Charts
import EasyTierShared
import SwiftUI

struct TrafficView: View {
    @Environment(EasyTierAppStore.self) private var store

    private static let rateMetricWidth: CGFloat = 136

    private var snapshot: RuntimeTrafficSnapshot { store.selectedTrafficSnapshot }
    private var latestUploadRate: String {
        snapshot.latest.map { ByteFormatter.formatRate($0.txBytesPerSecond) } ?? "\u{2014}"
    }

    private var latestDownloadRate: String {
        snapshot.latest.map { ByteFormatter.formatRate($0.rxBytesPerSecond) } ?? "\u{2014}"
    }

    private var samplingStatus: String {
        switch snapshot.samplingPhase {
        case .waiting:
            "Waiting"
        case .collecting:
            "Starting"
        case .live:
            "Live"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatusBadge(title: "Network", value: snapshot.networkName, systemImage: "globe")
                StatusBadge(title: "Upload", value: latestUploadRate, systemImage: "arrow.up", width: Self.rateMetricWidth)
                StatusBadge(title: "Download", value: latestDownloadRate, systemImage: "arrow.down", width: Self.rateMetricWidth)
                StatusBadge(title: "Sampling", value: samplingStatus, systemImage: "waveform.path.ecg")
                Spacer(minLength: 0)
            }

            MotionSwitch(id: snapshot.hasRunningInstance ? "chart" : "empty", insertionEdge: .bottom) {
                if !snapshot.hasRunningInstance {
                    ContentUnavailableView(
                        "No Traffic Data",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Run the selected network to start collecting traffic samples.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TrafficLineChart(snapshot: snapshot)
                        .equatable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding()
    }
}

private struct TrafficLineChart: View, Equatable {
    var snapshot: RuntimeTrafficSnapshot

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedSample: TrafficSample?

    private let uploadColor = EasyTierColors.metricUpload
    private let downloadColor = EasyTierColors.metricDownload

    nonisolated static func == (lhs: TrafficLineChart, rhs: TrafficLineChart) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Traffic trend")
                        .font(.headline.weight(.semibold))
                    Text(snapshot.timeSpanLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                HStack(spacing: 8) {
                    RateLegendItem(
                        color: uploadColor,
                        title: "Upload",
                        systemImage: "arrow.up"
                    )
                    RateLegendItem(
                        color: downloadColor,
                        title: "Download",
                        systemImage: "arrow.down"
                    )
                }
            }

            ZStack {
                if snapshot.displaySamples.isEmpty {
                    ContentUnavailableView(
                        emptyStateTitle,
                        systemImage: "waveform.path.ecg",
                        description: Text(emptyStateDescription)
                    )
                    .frame(maxWidth: .infinity, minHeight: 244)
                } else {
                    chart
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 244)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .frostedGlassBackground(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(panelStroke, lineWidth: 1)
        }
        .shadow(color: shadowColor, radius: 10, y: 5)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: snapshot)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selectedSample?.id)
        .onChange(of: snapshot.displaySamples) { _, newSamples in
            if let selectedSample, !newSamples.contains(where: { $0.id == selectedSample.id }) {
                self.selectedSample = nil
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(snapshot.displaySamples) { sample in
                AreaMark(
                    x: .value("Time", sample.timestamp),
                    yStart: .value("Baseline", 0.0),
                    yEnd: .value("Download", sample.rxBytesPerSecond),
                    series: .value("Series", seriesID(direction: "Download", sample: sample))
                )
                .foregroundStyle(areaGradient(color: downloadColor, sample: sample))
                .interpolationMethod(.linear)
            }

            ForEach(snapshot.displaySamples) { sample in
                AreaMark(
                    x: .value("Time", sample.timestamp),
                    yStart: .value("Baseline", 0.0),
                    yEnd: .value("Upload", sample.txBytesPerSecond),
                    series: .value("Series", seriesID(direction: "Upload", sample: sample))
                )
                .foregroundStyle(areaGradient(color: uploadColor, sample: sample))
                .interpolationMethod(.linear)
            }

            ForEach(snapshot.displaySamples) { sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Download", sample.rxBytesPerSecond),
                    series: .value("Series", seriesID(direction: "Download", sample: sample))
                )
                .foregroundStyle(lineColor(downloadColor, sample: sample))
                .lineStyle(downloadLineStyle)
                .interpolationMethod(.linear)
            }

            ForEach(snapshot.displaySamples) { sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Upload", sample.txBytesPerSecond),
                    series: .value("Series", seriesID(direction: "Upload", sample: sample))
                )
                .foregroundStyle(lineColor(uploadColor, sample: sample))
                .lineStyle(StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }

            if let resumeEvent = visibleResumeEvent {
                RuleMark(x: .value("Resume time", resumeEvent.timestamp))
                    .foregroundStyle(resumeRuleColor)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .annotation(position: .top, alignment: resumeAnnotationAlignment(for: resumeEvent), spacing: 5) {
                        Text(resumeLabel(for: resumeEvent))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                    }
            }

            if let selectedSample {
                RuleMark(x: .value("Selected time", selectedSample.timestamp))
                    .foregroundStyle(selectionColor)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 5]))

                PointMark(
                    x: .value("Selected upload time", selectedSample.timestamp),
                    y: .value("Selected upload", selectedSample.txBytesPerSecond)
                )
                .foregroundStyle(uploadColor)
                .symbolSize(38)

                PointMark(
                    x: .value("Selected download time", selectedSample.timestamp),
                    y: .value("Selected download", selectedSample.rxBytesPerSecond)
                )
                .foregroundStyle(downloadColor)
                .symbolSize(38)
            }

            if let latest = snapshot.latest {
                PointMark(
                    x: .value("Latest upload time", latest.timestamp),
                    y: .value("Latest upload", latest.txBytesPerSecond)
                )
                .foregroundStyle(uploadColor)
                .symbolSize(24)

                PointMark(
                    x: .value("Latest download time", latest.timestamp),
                    y: .value("Latest download", latest.rxBytesPerSecond)
                )
                .foregroundStyle(downloadColor)
                .symbolSize(24)
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: chartDomain)
        .chartYScale(domain: 0...snapshot.maxValue)
        .chartXAxis {
            AxisMarks(values: .stride(by: .second, count: 15)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6))
                    .foregroundStyle(axisGridColor.opacity(0.34))
                AxisTick(stroke: StrokeStyle(lineWidth: 0.6))
                    .foregroundStyle(axisGridColor.opacity(0.45))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(date: .omitted, time: .standard))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: RuntimeTrafficSnapshot.axisValues(maxValue: snapshot.maxValue)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7))
                    .foregroundStyle(axisGridColor)
                AxisValueLabel {
                    if let rate = value.as(Double.self) {
                        Text(ByteFormatter.formatRate(rate))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plotArea in
            plotArea
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .accessibilityLabel(Text("Traffic trend chart"))
        .accessibilityValue(Text(snapshot.accessibilitySummary))
        .accessibilityHint(Text("Shows upload and download rates over time"))
        .chartOverlay { chartProxy in
            GeometryReader { geometryProxy in
                if let plotFrame = chartProxy.plotFrame {
                    let plotRect = geometryProxy[plotFrame]

                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .overlay(alignment: .topLeading) {
                            selectionTooltip(chartProxy: chartProxy, plotRect: plotRect, chartSize: geometryProxy.size)
                        }
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case .active(let location):
                                updateSelection(at: location, chartProxy: chartProxy, plotRect: plotRect)
                            case .ended:
                                selectedSample = nil
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func selectionTooltip(chartProxy: ChartProxy, plotRect: CGRect, chartSize: CGSize) -> some View {
        if let selectedSample, let xPosition = chartProxy.position(forX: selectedSample.timestamp) {
            TrafficTooltip(sample: selectedSample, uploadColor: uploadColor, downloadColor: downloadColor)
                .fixedSize()
                .position(Self.tooltipPosition(forX: plotRect.minX + xPosition, in: plotRect, chartSize: chartSize))
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(2)
        }
    }

    private func updateSelection(at location: CGPoint, chartProxy: ChartProxy, plotRect: CGRect) {
        guard plotRect.contains(location) else {
            selectedSample = nil
            return
        }

        let xPosition = location.x - plotRect.minX
        guard let date = chartProxy.value(atX: xPosition, as: Date.self) else { return }
        selectedSample = Self.closestSample(to: date, in: snapshot.displaySamples)
    }

    private var visibleResumeEvent: TrafficResumeEvent? {
        guard let event = snapshot.resumeEvent,
              let windowStart = snapshot.windowStart,
              let windowEnd = snapshot.windowEnd,
              event.timestamp >= windowStart,
              event.timestamp <= windowEnd
        else {
            return nil
        }
        return event
    }

    private var chartDomain: ClosedRange<Date> {
        let fallbackEnd = snapshot.displaySamples.last?.timestamp ?? Date()
        let end = snapshot.windowEnd ?? fallbackEnd
        let start = snapshot.windowStart ?? end.addingTimeInterval(-60)
        return start < end ? (start...end) : (start...start.addingTimeInterval(60))
    }

    private var emptyStateTitle: String {
        switch snapshot.samplingPhase {
        case .waiting:
            "Waiting for traffic data"
        case .collecting:
            "Collecting new samples"
        case .live:
            "No recent traffic"
        }
    }

    private var emptyStateDescription: String {
        switch snapshot.samplingPhase {
        case .waiting:
            "Traffic sampling will begin when the network starts."
        case .collecting:
            "Rates will appear after the next polling interval."
        case .live:
            "New activity will appear in the live 60-second window."
        }
    }

    private var downloadLineStyle: StrokeStyle {
        StrokeStyle(
            lineWidth: 2.1,
            lineCap: .round,
            lineJoin: .round,
            dash: differentiateWithoutColor ? [6, 4] : []
        )
    }

    private var resumeRuleColor: Color {
        Color.secondary.opacity(colorScheme == .dark ? 0.42 : 0.34)
    }

    private func isActive(_ sample: TrafficSample) -> Bool {
        snapshot.activeSessionID.map { $0 == sample.sessionID } ?? true
    }

    private func lineColor(_ color: Color, sample: TrafficSample) -> Color {
        color.opacity(isActive(sample) ? 1 : 0.45)
    }

    private func areaGradient(color: Color, sample: TrafficSample) -> LinearGradient {
        LinearGradient(
            colors: [color.opacity(isActive(sample) ? 0.07 : 0.02), color.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func seriesID(direction: String, sample: TrafficSample) -> String {
        "\(direction)-\(sample.sessionID.uuidString)"
    }

    private func resumeLabel(for event: TrafficResumeEvent) -> String {
        switch event.reason {
        case .gap:
            "Resumed"
        case .counterReset:
            "Sampling restarted"
        case .clockAdjusted:
            "Clock adjusted"
        }
    }

    private func resumeAnnotationAlignment(for event: TrafficResumeEvent) -> Alignment {
        let midpoint = chartDomain.lowerBound.addingTimeInterval(
            chartDomain.upperBound.timeIntervalSince(chartDomain.lowerBound) / 2
        )
        return event.timestamp > midpoint ? .trailing : .leading
    }

    private var panelStroke: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.06)
    }

    private var shadowColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.07)
    }

    private var axisGridColor: Color {
        Color.primary.opacity(0.085)
    }

    private var selectionColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.38 : 0.28)
    }

    private static func closestSample(to date: Date, in samples: [TrafficSample]) -> TrafficSample? {
        guard let closest = samples.min(by: { lhs, rhs in
            abs(lhs.timestamp.timeIntervalSince(date)) < abs(rhs.timestamp.timeIntervalSince(date))
        }) else { return nil }
        guard abs(closest.timestamp.timeIntervalSince(date)) <= 2 else { return nil }
        return closest
    }

    private static func tooltipPosition(forX x: CGFloat, in rect: CGRect, chartSize: CGSize) -> CGPoint {
        let tooltipWidth: CGFloat = 184
        let tooltipHeight: CGFloat = 88
        let preferredX = x + 16
        let clampedX = min(max(preferredX, tooltipWidth / 2 + 8), chartSize.width - tooltipWidth / 2 - 8)
        let y = max(rect.minY + tooltipHeight / 2 + 8, tooltipHeight / 2 + 8)
        return CGPoint(x: clampedX, y: y)
    }
}

private struct RateLegendItem: View {
    var color: Color
    var title: String
    var systemImage: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 12)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct TrafficTooltip: View {
    @Environment(\.colorScheme) private var colorScheme

    var sample: TrafficSample
    var uploadColor: Color
    var downloadColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sample.timestamp.formatted(date: .omitted, time: .standard))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 6) {
                TooltipRateRow(color: uploadColor, title: "Upload", value: ByteFormatter.formatRate(sample.txBytesPerSecond))
                TooltipRateRow(color: downloadColor, title: "Download", value: ByteFormatter.formatRate(sample.rxBytesPerSecond))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tooltipStroke, lineWidth: 1)
        }
        .shadow(color: Color.primary.opacity(colorScheme == .dark ? 0.20 : 0.10), radius: 9, y: 4)
    }

    private var tooltipStroke: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.07)
    }
}

private struct TooltipRateRow: View {
    var color: Color
    var title: String
    var value: String

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(title): \(value)")
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
    }
}
