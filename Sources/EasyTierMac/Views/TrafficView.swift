import EasyTierShared
import SwiftUI

struct TrafficView: View {
    @Environment(EasyTierAppStore.self) private var store

    private var instance: NetworkInstance? { store.selectedRunningInstance }
    private var samples: [TrafficSample] { store.selectedTrafficSamples }
    private var latest: TrafficSample? { samples.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatusMetric(title: "Network", value: instance?.name ?? store.selectedConfig?.network_name ?? "-", systemImage: "network")
                StatusMetric(title: "Upload", value: ByteFormatter.formatRate(latest?.txBytesPerSecond ?? 0), systemImage: "arrow.up")
                StatusMetric(title: "Download", value: ByteFormatter.formatRate(latest?.rxBytesPerSecond ?? 0), systemImage: "arrow.down")
                StatusMetric(title: "Samples", value: "\(samples.count)", systemImage: "waveform.path.ecg")
                Spacer(minLength: 0)
            }

            if instance == nil {
                ContentUnavailableView(
                    "No Traffic Data",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Run the selected network to start collecting traffic samples.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TrafficLineChart(samples: samples)
                    .frame(minHeight: 300)
            }
        }
        .padding()
    }
}

private struct StatusMetric: View {
    var title: String
    var value: String
    var systemImage: String

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
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LegendItem: View {
    var color: Color
    var title: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TrafficLineChart: View {
    var samples: [TrafficSample]

    @State private var hoverLocation: CGPoint?

    private let uploadColor = Color(red: 0.13, green: 0.82, blue: 0.39)
    private let downloadColor = Color(red: 0.24, green: 0.55, blue: 1.0)
    private let panelBackground = Color(red: 0.08, green: 0.10, blue: 0.18)
    private let gridColor = Color.white.opacity(0.06)

    private var latest: TrafficSample? { samples.last }

    var body: some View {
        GeometryReader { proxy in
            let plotRect = Self.plotRect(for: proxy.size)
            let hoveredIndex = Self.sampleIndex(at: hoverLocation, in: plotRect, count: samples.count)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let plotRect = Self.plotRect(for: size)
                    let maxValue = Self.maxChartValue(for: samples)
                    let txValues = samples.map(\.txBytesPerSecond)
                    let rxValues = samples.map(\.rxBytesPerSecond)

                    drawGrid(in: plotRect, context: &context, maxValue: maxValue)
                    drawArea(values: rxValues, in: plotRect, maxValue: maxValue, color: downloadColor, context: &context)
                    drawLine(values: rxValues, in: plotRect, maxValue: maxValue, color: downloadColor, context: &context)
                    drawLine(values: txValues, in: plotRect, maxValue: maxValue, color: uploadColor, context: &context)

                    if let hoveredIndex, samples.indices.contains(hoveredIndex) {
                        drawHoverIndicator(index: hoveredIndex, in: plotRect, maxValue: maxValue, context: &context)
                    }
                }
                .overlay(alignment: .top) {
                    HStack(spacing: 32) {
                        RateLegendItem(color: uploadColor, title: "上传", value: ByteFormatter.formatRate(latest?.txBytesPerSecond ?? 0))
                        RateLegendItem(color: downloadColor, title: "下载", value: ByteFormatter.formatRate(latest?.rxBytesPerSecond ?? 0))
                    }
                    .padding(.top, 26)
                }
                .overlay(alignment: .bottomLeading) {
                    HStack {
                        AxisTimeLabel(samples.first?.timestamp)
                        Spacer()
                        AxisTimeLabel(samples.last?.timestamp)
                    }
                    .padding(.leading, plotRect.minX)
                    .padding(.trailing, proxy.size.width - plotRect.maxX)
                    .padding(.bottom, 10)
                }
                .overlay(alignment: .topLeading) {
                    if let hoveredIndex, samples.indices.contains(hoveredIndex) {
                        TrafficTooltip(sample: samples[hoveredIndex], uploadColor: uploadColor, downloadColor: downloadColor)
                            .fixedSize()
                            .position(Self.tooltipPosition(for: hoveredIndex, in: plotRect, chartSize: proxy.size, sampleCount: samples.count))
                            .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        hoverLocation = location
                    case .ended:
                        hoverLocation = nil
                    }
                }

                if samples.isEmpty {
                    ContentUnavailableView("等待流量数据", systemImage: "waveform.path.ecg")
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .background(panelBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(red: 0.11, green: 0.33, blue: 1.0), lineWidth: 1.6)
            }
        }
    }

    private static func plotRect(for size: CGSize) -> CGRect {
        CGRect(
            x: 58,
            y: 78,
            width: max(1, size.width - 86),
            height: max(1, size.height - 122)
        )
    }

    private static func maxChartValue(for samples: [TrafficSample]) -> Double {
        let maxSampleValue = samples.lazy.flatMap { [$0.txBytesPerSecond, $0.rxBytesPerSecond] }.max() ?? 0
        return niceAxisMaximum(max(maxSampleValue, 1))
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

    private static func sampleIndex(at location: CGPoint?, in rect: CGRect, count: Int) -> Int? {
        guard let location, count > 0, rect.contains(location) else { return nil }
        guard count > 1 else { return 0 }
        let progress = min(max((location.x - rect.minX) / rect.width, 0), 1)
        return min(count - 1, max(0, Int((progress * CGFloat(count - 1)).rounded())))
    }

    private static func tooltipPosition(for index: Int, in rect: CGRect, chartSize: CGSize, sampleCount: Int) -> CGPoint {
        let x: CGFloat
        if sampleCount > 1 {
            x = rect.minX + rect.width * CGFloat(index) / CGFloat(sampleCount - 1)
        } else {
            x = rect.midX
        }

        let tooltipWidth: CGFloat = 172
        let tooltipHeight: CGFloat = 112
        let clampedX = min(max(x + 14, tooltipWidth / 2 + 8), chartSize.width - tooltipWidth / 2 - 8)
        let y = max(rect.minY + tooltipHeight / 2 - 8, tooltipHeight / 2 + 8)
        return CGPoint(x: clampedX, y: y)
    }

    private func drawGrid(in rect: CGRect, context: inout GraphicsContext, maxValue: Double) {
        var grid = Path()
        for index in 0...4 {
            let y = rect.minY + rect.height * CGFloat(index) / 4
            grid.move(to: CGPoint(x: rect.minX, y: y))
            grid.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.stroke(grid, with: .color(gridColor), lineWidth: 1)

        for index in 0...5 {
            let value = maxValue * Double(5 - index) / 5
            let y = rect.minY + rect.height * CGFloat(index) / 5
            context.draw(
                Text(ByteFormatter.formatRate(value))
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.36)),
                at: CGPoint(x: rect.minX - 12, y: y),
                anchor: .trailing
            )
        }
    }

    private func drawArea(values: [Double], in rect: CGRect, maxValue: Double, color: Color, context: inout GraphicsContext) {
        guard values.count > 1 else { return }

        var area = linePath(values: values, in: rect, maxValue: maxValue)
        area.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        area.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        area.closeSubpath()
        context.fill(area, with: .color(color.opacity(0.16)))
    }

    private func drawLine(values: [Double], in rect: CGRect, maxValue: Double, color: Color, context: inout GraphicsContext) {
        guard values.count > 1 else { return }

        let path = linePath(values: values, in: rect, maxValue: maxValue)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }

    private func drawHoverIndicator(index: Int, in rect: CGRect, maxValue: Double, context: inout GraphicsContext) {
        guard samples.indices.contains(index) else { return }
        let sample = samples[index]
        let x: CGFloat
        if samples.count > 1 {
            x = rect.minX + rect.width * CGFloat(index) / CGFloat(samples.count - 1)
        } else {
            x = rect.midX
        }

        var indicator = Path()
        indicator.move(to: CGPoint(x: x, y: rect.minY))
        indicator.addLine(to: CGPoint(x: x, y: rect.maxY))
        context.stroke(indicator, with: .color(Color.white.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))

        drawPoint(value: sample.rxBytesPerSecond, x: x, in: rect, maxValue: maxValue, color: downloadColor, context: &context)
        drawPoint(value: sample.txBytesPerSecond, x: x, in: rect, maxValue: maxValue, color: uploadColor, context: &context)
    }

    private func drawPoint(value: Double, x: CGFloat, in rect: CGRect, maxValue: Double, color: Color, context: inout GraphicsContext) {
        let y = rect.maxY - rect.height * CGFloat(min(max(value, 0), maxValue) / maxValue)
        let pointRect = CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
        context.fill(Path(ellipseIn: pointRect.insetBy(dx: -2, dy: -2)), with: .color(panelBackground.opacity(0.9)))
        context.fill(Path(ellipseIn: pointRect), with: .color(color))
    }

    private func linePath(values: [Double], in rect: CGRect, maxValue: Double) -> Path {
        var path = Path()
        for (index, value) in values.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = rect.maxY - rect.height * CGFloat(min(max(value, 0), maxValue) / maxValue)
            let point = CGPoint(x: x, y: y)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

private struct RateLegendItem: View {
    var color: Color
    var title: String
    var value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text("\(title): \(value)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }
}

private struct AxisTimeLabel: View {
    var timestamp: Date?

    init(_ timestamp: Date?) {
        self.timestamp = timestamp
    }

    var body: some View {
        Text(timestamp?.formatted(date: .omitted, time: .standard) ?? "--:--:--")
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.white.opacity(0.35))
            .monospacedDigit()
    }
}

private struct TrafficTooltip: View {
    var sample: TrafficSample
    var uploadColor: Color
    var downloadColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(sample.timestamp.formatted(date: .omitted, time: .standard))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 6) {
                TooltipRateRow(color: uploadColor, title: "上传", value: ByteFormatter.formatRate(sample.txBytesPerSecond))
                TooltipRateRow(color: downloadColor, title: "下载", value: ByteFormatter.formatRate(sample.rxBytesPerSecond))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
    }
}

private struct TooltipRateRow: View {
    var color: Color
    var title: String
    var value: String

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.white)
                .frame(width: 16, height: 16)
                .overlay {
                    RoundedRectangle(cornerRadius: 1.5)
                        .stroke(color, lineWidth: 3)
                }
            Text("\(title): \(value)")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
    }
}
