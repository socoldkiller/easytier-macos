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
    var templateMode = false

    @State private var activeConnectingNodeIndex = 0

    var body: some View {
        ZStack {
            ConnectionGlyphLines(state: state, templateMode: templateMode)
                .stroke(lineColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .opacity(lineOpacity)

            ForEach(ConnectionGlyphNode.allCases) { node in
                nodeView(for: node, activeConnectingNode: activeConnectingNode)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.16), value: activeConnectingNode)
        .task(id: state) {
            await runConnectingAnimationIfNeeded()
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private static let stepDurationNanoseconds: UInt64 = 340_000_000

    private var activeConnectingNode: ConnectionGlyphNode? {
        guard state == .connecting else { return nil }
        return Self.connectingSequence[activeConnectingNodeIndex % Self.connectingSequence.count]
    }

    private static let connectingSequence: [ConnectionGlyphNode] = [.top, .bottomRight, .bottomLeft]

    private func runConnectingAnimationIfNeeded() async {
        guard state == .connecting else {
            activeConnectingNodeIndex = 0
            return
        }

        activeConnectingNodeIndex = 0
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: Self.stepDurationNanoseconds)
            } catch {
                break
            }
            activeConnectingNodeIndex = (activeConnectingNodeIndex + 1) % Self.connectingSequence.count
        }
    }

    private var lineWidth: CGFloat {
        max(size * 0.072, 1.05)
    }

    private var nodeSize: CGFloat {
        max(size * 0.28 - 0.5, 3.9)
    }

    private var lineOpacity: Double {
        switch state {
        case .idle: 0.16
        case .connecting: 0.38
        case .connected: 0.56
        case .error: 0.36
        }
    }

    private var lineColor: Color {
        if templateMode { return .primary.opacity(state == .idle ? 0.42 : 0.72) }
        switch state {
        case .idle: return .secondary
        case .connecting, .connected, .error: return .primary
        }
    }

    private func nodeView(for node: ConnectionGlyphNode, activeConnectingNode: ConnectionGlyphNode?) -> some View {
        let position = node.position(in: size)
        return Circle()
            .fill(nodeFill(for: node, activeConnectingNode: activeConnectingNode))
            .overlay {
                Circle()
                    .stroke(nodeStroke(for: node), lineWidth: nodeStrokeWidth)
            }
            .frame(width: nodeSize, height: nodeSize)
            .position(position)
    }

    private var nodeStrokeWidth: CGFloat {
        0
    }

    private func nodeFill(for node: ConnectionGlyphNode, activeConnectingNode: ConnectionGlyphNode?) -> Color {
        if templateMode {
            return .primary.opacity(nodeOpacity(for: node, activeConnectingNode: activeConnectingNode))
        }

        return .primary.opacity(nodeOpacity(for: node, activeConnectingNode: activeConnectingNode))
    }

    private func nodeOpacity(for node: ConnectionGlyphNode, activeConnectingNode: ConnectionGlyphNode?) -> Double {
        switch state {
        case .idle:
            return 0.26
        case .connecting:
            return node == activeConnectingNode ? 0.86 : 0.26
        case .connected:
            return 0.86
        case .error:
            return node == .bottomRight ? 0.86 : 0.28
        }
    }

    private func nodeStroke(for node: ConnectionGlyphNode) -> Color {
        .clear
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

private enum ConnectionGlyphNode: CaseIterable, Identifiable {
    case top
    case bottomLeft
    case bottomRight

    var id: Self { self }

    func position(in size: CGFloat) -> CGPoint {
        switch self {
        case .top:
            CGPoint(x: size * 0.50, y: size * 0.18)
        case .bottomLeft:
            CGPoint(x: size * 0.23, y: size * 0.78)
        case .bottomRight:
            CGPoint(x: size * 0.77, y: size * 0.78)
        }
    }
}

private struct ConnectionGlyphLines: Shape {
    var state: ConnectionGlyphState
    var templateMode: Bool

    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - size / 2, y: rect.midY - size / 2)

        func point(_ node: ConnectionGlyphNode) -> CGPoint {
            let position = node.position(in: size)
            return CGPoint(x: origin.x + position.x, y: origin.y + position.y)
        }

        var path = Path()

        func addSegment(from start: ConnectionGlyphNode, to end: ConnectionGlyphNode, gap: CGFloat = size * 0.28) {
            let startPoint = point(start)
            let endPoint = point(end)
            let dx = endPoint.x - startPoint.x
            let dy = endPoint.y - startPoint.y
            let length = max(sqrt(dx * dx + dy * dy), 0.001)
            let inset = min(gap, length * 0.43)
            let unit = CGPoint(x: dx / length, y: dy / length)
            path.move(to: CGPoint(x: startPoint.x + unit.x * inset, y: startPoint.y + unit.y * inset))
            path.addLine(to: CGPoint(x: endPoint.x - unit.x * inset, y: endPoint.y - unit.y * inset))
        }

        switch state {
        case .idle:
            addSegment(from: .top, to: .bottomLeft)
        case .connecting:
            addSegment(from: .top, to: .bottomLeft)
            addSegment(from: .bottomLeft, to: .bottomRight)
            addSegment(from: .bottomRight, to: .top)
        case .connected:
            addSegment(from: .top, to: .bottomLeft)
            addSegment(from: .bottomLeft, to: .bottomRight)
            addSegment(from: .bottomRight, to: .top)
        case .error:
            addSegment(from: .top, to: .bottomLeft)
        }

        return path
    }
}
