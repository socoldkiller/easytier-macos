import SwiftUI

enum ConnectionGlyphState: Equatable {
    case idle
    case connecting
    case connected
    case error
}

struct ConnectionGlyph: View {
    var state: ConnectionGlyphState
    var size: CGFloat = 18

    @State private var activeNodeIndex = 0

    var body: some View {
        ZStack {
            ForEach(0..<Self.nodeCount, id: \.self) { segIndex in
                segmentView(segIndex)
            }

            ForEach(0..<Self.nodeCount, id: \.self) { index in
                nodeView(index)
            }
        }
        .frame(width: size, height: size)
        .task(id: state) {
            await runConnectingAnimationIfNeeded()
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private static let nodeCount = 3
    private static let stepDurationNanoseconds: UInt64 = 340_000_000

    private func runConnectingAnimationIfNeeded() async {
        guard state == .connecting else {
            activeNodeIndex = 0
            return
        }

        activeNodeIndex = 0
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: Self.stepDurationNanoseconds)
            } catch {
                break
            }
            withAnimation(.easeInOut(duration: Double(Self.stepDurationNanoseconds) / 1_000_000_000)) {
                activeNodeIndex = (activeNodeIndex + 1) % Self.nodeCount
            }
        }
    }

    private var lineWidth: CGFloat {
        max(size * 0.048, 0.75)
    }

    private var nodeRadius: CGFloat {
        max(size * 0.130, 1.90)
    }

    private var ringStroke: CGFloat {
        max(size * 0.105, 1.65)
    }

    private var lineInset: CGFloat {
        size * 0.12
    }

    private var dashPattern: [CGFloat] {
        [size * 0.16, size * 0.064]
    }

    private var nodeCenters: [CGPoint] {
        [
            CGPoint(x: size * 0.50, y: size * 0.36),
            CGPoint(x: size * 0.23, y: size * 0.82),
            CGPoint(x: size * 0.77, y: size * 0.82),
        ]
    }

    private var lineColor: Color {
        switch state {
        case .idle: return .black.opacity(0.34)
        case .connected, .error: return .black.opacity(0.72)
        case .connecting: return .black.opacity(0.50)
        }
    }

    private var statusColor: Color? {
        switch state {
        case .idle: nil
        case .connecting: .orange
        case .connected: Color(nsColor: .systemGreen)
        case .error: .red
        }
    }

    private func segmentPath(_ segIndex: Int) -> Path {
        let start = nodeCenters[segIndex]
        let end = nodeCenters[(segIndex + 1) % Self.nodeCount]
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(sqrt(dx * dx + dy * dy), 0.001)
        let inset = min(lineInset, length * 0.43)
        let unit = CGPoint(x: dx / length, y: dy / length)
        var path = Path()
        path.move(to: CGPoint(x: start.x + unit.x * inset, y: start.y + unit.y * inset))
        path.addLine(to: CGPoint(x: end.x - unit.x * inset, y: end.y - unit.y * inset))
        return path
    }

    @ViewBuilder
    private func segmentView(_ segIndex: Int) -> some View {
        switch state {
        case .idle, .connected, .error:
            segmentPath(segIndex).stroke(lineColor, style: StrokeStyle(
                lineWidth: lineWidth,
                lineCap: .round,
                lineJoin: .round
            ))
        case .connecting:
            segmentPath(segIndex).stroke(lineColor, style: StrokeStyle(
                lineWidth: lineWidth,
                lineCap: .round,
                lineJoin: .round
            ))
            if segIndex == activeNodeIndex, let statusColor {
                segmentPath(segIndex).stroke(statusColor, style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .butt,
                    lineJoin: .round,
                    dash: dashPattern
                ))
            }
        }
    }

    @ViewBuilder
    private func nodeView(_ index: Int) -> some View {
        let position = nodeCenters[index]
        let diameter = nodeRadius * 2
        let fill: Color? = {
            switch state {
            case .idle:
                return nil
            case .connecting:
                return index == activeNodeIndex ? statusColor : nil
            case .connected, .error:
                return statusColor
            }
        }()
        ZStack {
            if let fill {
                Circle()
                    .fill(fill)
                    .frame(width: diameter, height: diameter)
            }
            Circle()
                .stroke(Color.black.opacity(0.82), lineWidth: ringStroke)
                .frame(width: diameter, height: diameter)
        }
        .position(position)
    }

    private var accessibilityLabel: Text {
        switch state {
        case .idle: Text("Disconnected")
        case .connecting: Text("Connecting")
        case .connected: Text("Connected")
        case .error: Text("Connection error")
        }
    }
}
