import AppKit
import Charts
import EasyTierShared
import SwiftUI

struct TrafficView: View {
    @Environment(EasyTierAppStore.self) private var store

    private static let rateMetricWidth: CGFloat = 136

    private var snapshot: RuntimeTrafficSnapshot { store.selectedTrafficSnapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatusBadge(title: "Network", value: snapshot.networkName, systemImage: "globe")
                StatusBadge(title: "Upload", value: ByteFormatter.formatRate(snapshot.latest?.txBytesPerSecond ?? 0), systemImage: "arrow.up", width: Self.rateMetricWidth)
                StatusBadge(title: "Download", value: ByteFormatter.formatRate(snapshot.latest?.rxBytesPerSecond ?? 0), systemImage: "arrow.down", width: Self.rateMetricWidth)
                StatusBadge(title: "Samples", value: "\(snapshot.samples.count)", systemImage: "waveform.path.ecg")
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
                        value: ByteFormatter.formatRate(snapshot.latest?.txBytesPerSecond ?? 0),
                        systemImage: "arrow.up"
                    )
                    RateLegendItem(
                        color: downloadColor,
                        title: "Download",
                        value: ByteFormatter.formatRate(snapshot.latest?.rxBytesPerSecond ?? 0),
                        systemImage: "arrow.down"
                    )
                }
            }

            ZStack {
                if snapshot.displaySamples.isEmpty {
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
        .frostedGlassBackground(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(panelStroke, lineWidth: 1)
        }
        .shadow(color: shadowColor, radius: 10, y: 5)
        .animation(.easeOut(duration: 0.16), value: selectedSample?.id)
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
                    series: .value("Direction", "Download")
                )
                .foregroundStyle(downloadAreaGradient)
                .interpolationMethod(.linear)
            }

            ForEach(snapshot.displaySamples) { sample in
                AreaMark(
                    x: .value("Time", sample.timestamp),
                    yStart: .value("Baseline", 0.0),
                    yEnd: .value("Upload", sample.txBytesPerSecond),
                    series: .value("Direction", "Upload")
                )
                .foregroundStyle(uploadAreaGradient)
                .interpolationMethod(.linear)
            }

            ForEach(snapshot.displaySamples) { sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Download", sample.rxBytesPerSecond),
                    series: .value("Direction", "Download")
                )
                .foregroundStyle(downloadColor)
                .lineStyle(StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }

            ForEach(snapshot.displaySamples) { sample in
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
        .chartYScale(domain: 0...snapshot.maxValue)
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

    private var uploadAreaGradient: LinearGradient {
        LinearGradient(colors: [uploadColor.opacity(0.11), uploadColor.opacity(0.0)], startPoint: .top, endPoint: .bottom)
    }

    private var downloadAreaGradient: LinearGradient {
        LinearGradient(colors: [downloadColor.opacity(0.13), downloadColor.opacity(0.0)], startPoint: .top, endPoint: .bottom)
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
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
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
