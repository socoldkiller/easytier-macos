import AppKit
import Charts
import EasyTierShared
import SwiftUI

struct TrafficView: View {
    @Environment(EasyTierAppStore.self) private var store

    private static let rateMetricWidth: CGFloat = 136

    private var instance: NetworkInstance? { store.selectedRunningInstance }
    private var samples: [TrafficSample] { store.selectedTrafficSamples }
    private var latest: TrafficSample? { samples.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatusMetric(title: "Network", value: instance?.name ?? store.selectedConfig?.network_name ?? "-", systemImage: "network")
                StatusMetric(title: "Upload", value: ByteFormatter.formatRate(latest?.txBytesPerSecond ?? 0), systemImage: "arrow.up", width: Self.rateMetricWidth)
                StatusMetric(title: "Download", value: ByteFormatter.formatRate(latest?.rxBytesPerSecond ?? 0), systemImage: "arrow.down", width: Self.rateMetricWidth)
                StatusMetric(title: "Samples", value: "\(samples.count)", systemImage: "waveform.path.ecg")
                Spacer(minLength: 0)
            }

            MotionSwitch(id: instance == nil ? "empty" : "chart", insertionEdge: .bottom) {
                if instance == nil {
                    ContentUnavailableView(
                        "No Traffic Data",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Run the selected network to start collecting traffic samples.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TrafficLineChart(samples: samples)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding()
    }
}

private struct StatusMetric: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var title: String
    var value: String
    var systemImage: String
    var width: CGFloat? = nil

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(width: width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: value)
    }
}

private struct TrafficLineChart: View {
    var samples: [TrafficSample]

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedSample: TrafficSample?

    private let uploadColor = Color(red: 0.24, green: 0.74, blue: 0.50)
    private let downloadColor = Color(red: 0.35, green: 0.57, blue: 0.96)

    private var displaySamples: [TrafficSample] {
        samples
            .filter { sample in
                sample.timestamp.timeIntervalSinceReferenceDate.isFinite
                    && sample.txBytesPerSecond.isFinite
                    && sample.rxBytesPerSecond.isFinite
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var latest: TrafficSample? { displaySamples.last }
    private var maxValue: Double { Self.maxChartValue(for: displaySamples) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Traffic trend")
                        .font(.headline.weight(.semibold))
                    Text(timeSpanLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                HStack(spacing: 8) {
                    RateLegendItem(color: uploadColor, title: "Upload", value: ByteFormatter.formatRate(latest?.txBytesPerSecond ?? 0))
                    RateLegendItem(color: downloadColor, title: "Download", value: ByteFormatter.formatRate(latest?.rxBytesPerSecond ?? 0))
                }
            }

            ZStack {
                if displaySamples.isEmpty {
                    ContentUnavailableView(
                        "Waiting for traffic data",
                        systemImage: "waveform.path.ecg",
                        description: Text("Rates will appear after the next polling interval.")
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
        .background(panelFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(panelStroke, lineWidth: 1)
        }
        .shadow(color: shadowColor, radius: 10, y: 5)
        .animation(.easeOut(duration: 0.16), value: selectedSample?.id)
        .onChange(of: samples) { _, newSamples in
            if let selectedSample, !newSamples.contains(where: { $0.id == selectedSample.id }) {
                self.selectedSample = nil
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(displaySamples) { sample in
                AreaMark(
                    x: .value("Time", sample.timestamp),
                    yStart: .value("Baseline", 0.0),
                    yEnd: .value("Download", sample.rxBytesPerSecond),
                    series: .value("Direction", "Download")
                )
                .foregroundStyle(downloadAreaGradient)
                .interpolationMethod(.linear)
            }

            ForEach(displaySamples) { sample in
                AreaMark(
                    x: .value("Time", sample.timestamp),
                    yStart: .value("Baseline", 0.0),
                    yEnd: .value("Upload", sample.txBytesPerSecond),
                    series: .value("Direction", "Upload")
                )
                .foregroundStyle(uploadAreaGradient)
                .interpolationMethod(.linear)
            }

            ForEach(displaySamples) { sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Download", sample.rxBytesPerSecond),
                    series: .value("Direction", "Download")
                )
                .foregroundStyle(downloadColor)
                .lineStyle(StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }

            ForEach(displaySamples) { sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Upload", sample.txBytesPerSecond),
                    series: .value("Direction", "Upload")
                )
                .foregroundStyle(uploadColor)
                .lineStyle(StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
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

            if let latest {
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
        .chartYScale(domain: 0...maxValue)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
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
            AxisMarks(position: .leading, values: Self.axisValues(maxValue: maxValue)) { value in
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
                .background(plotFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(plotStroke, lineWidth: 1)
                }
        }
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
        selectedSample = Self.closestSample(to: date, in: displaySamples)
    }

    private var timeSpanLabel: String {
        guard let first = displaySamples.first?.timestamp, let last = displaySamples.last?.timestamp else {
            return "Waiting for samples"
        }
        guard displaySamples.count > 1 else {
            return "Collecting samples"
        }
        let seconds = max(0, last.timeIntervalSince(first))
        if seconds < 90 {
            return "Last \(Int(seconds.rounded())) sec"
        }
        return "Last \(String(format: "%.1f", seconds / 60)) min"
    }

    private var panelFill: AnyShapeStyle {
        let color = Color(nsColor: colorScheme == .dark ? .controlBackgroundColor : .windowBackgroundColor)
        return AnyShapeStyle(color.opacity(colorScheme == .dark ? 0.86 : 0.96))
    }

    private var panelStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.06)
    }

    private var shadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.08 : 0.07)
    }

    private var plotFill: Color {
        colorScheme == .dark ? Color.black.opacity(0.10) : Color(nsColor: .controlBackgroundColor).opacity(0.55)
    }

    private var plotStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.035) : Color.black.opacity(0.045)
    }

    private var axisGridColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.085) : Color.black.opacity(0.085)
    }

    private var selectionColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.38) : Color.black.opacity(0.28)
    }

    private var uploadAreaGradient: LinearGradient {
        LinearGradient(colors: [uploadColor.opacity(0.11), uploadColor.opacity(0.0)], startPoint: .top, endPoint: .bottom)
    }

    private var downloadAreaGradient: LinearGradient {
        LinearGradient(colors: [downloadColor.opacity(0.13), downloadColor.opacity(0.0)], startPoint: .top, endPoint: .bottom)
    }

    private static func maxChartValue(for samples: [TrafficSample]) -> Double {
        let maxSampleValue = samples.lazy.flatMap { [$0.txBytesPerSecond, $0.rxBytesPerSecond] }.max() ?? 0
        return niceAxisMaximum(max(maxSampleValue, 16))
    }

    private static func axisValues(maxValue: Double) -> [Double] {
        (0...4).map { maxValue * Double($0) / 4 }
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

    private static func closestSample(to date: Date, in samples: [TrafficSample]) -> TrafficSample? {
        samples.min { lhs, rhs in
            abs(lhs.timestamp.timeIntervalSince(date)) < abs(rhs.timestamp.timeIntervalSince(date))
        }
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
    var value: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 18, height: 3)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(color.opacity(0.18), lineWidth: 1)
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
        .background(tooltipFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tooltipStroke, lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.20 : 0.10), radius: 9, y: 4)
    }

    private var tooltipFill: Color {
        Color(nsColor: colorScheme == .dark ? .controlBackgroundColor : .windowBackgroundColor).opacity(0.98)
    }

    private var tooltipStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07)
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
