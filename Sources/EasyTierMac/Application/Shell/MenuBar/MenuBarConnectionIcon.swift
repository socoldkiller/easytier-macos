import AppKit
import EasyTierShared
import Foundation

enum MenuBarConnectionIcon {
    private static let canvas: CGFloat = 22
    private static let nodeRadius: CGFloat = 2.95
    private static let nodeStroke: CGFloat = 1.75
    private static let lineWidth: CGFloat = 1.05
    private static let lineInset: CGFloat = 2.85

    private static let nodeCenters: [CGPoint] = [
        CGPoint(x: 11, y: 17.15),
        CGPoint(x: 4.25, y: 3.7),
        CGPoint(x: 17.75, y: 3.7),
    ]
    private static let segments: [(Int, Int)] = [(0, 1), (1, 2), (2, 0)]

    static func image(
        for state: ConnectionGlyphState,
        activeNodeIndex: Int? = nil,
        appearance: NSAppearance
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.lockFocus()
        defer { image.unlockFocus() }

        appearance.performAsCurrentDrawingAppearance {
            if state == .connecting {
                for (a, b) in segments {
                    drawSegment(from: nodeCenters[a], to: nodeCenters[b], color: lineColor(for: state))
                }
            }

            for (segmentIndex, (startIndex, endIndex)) in segments.enumerated() {
                switch state {
                case .idle, .connected, .error:
                    drawSegment(
                        from: nodeCenters[startIndex],
                        to: nodeCenters[endIndex],
                        color: lineColor(for: state)
                    )
                case .connecting:
                    if let activeNodeIndex, segmentIndex == activeNodeIndex {
                        drawSegment(
                            from: nodeCenters[startIndex],
                            to: nodeCenters[endIndex],
                            dashed: true,
                            color: statusColor(for: state) ?? .systemOrange
                        )
                    }
                }
            }

            for (index, point) in nodeCenters.enumerated() {
                let fill: NSColor?
                switch state {
                case .idle:
                    fill = nil
                case .connecting:
                    fill = index == activeNodeIndex ? statusColor(for: state) : nil
                case .connected, .error:
                    fill = statusColor(for: state)
                }
                drawNode(at: point, fill: fill)
            }
        }

        image.isTemplate = false
        return image
    }

    private static func drawSegment(
        from start: CGPoint,
        to end: CGPoint,
        dashed: Bool = false,
        color: NSColor
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(sqrt(dx * dx + dy * dy), 0.001)
        let inset = min(lineInset, length * 0.43)
        let unit = CGPoint(x: dx / length, y: dy / length)
        let path = NSBezierPath()

        path.lineWidth = lineWidth
        path.lineCapStyle = dashed ? .butt : .round
        path.lineJoinStyle = .round
        if dashed {
            path.setLineDash([3.4, 1.4], count: 2, phase: 0)
        }
        path.move(to: CGPoint(x: start.x + unit.x * inset, y: start.y + unit.y * inset))
        path.line(to: CGPoint(x: end.x - unit.x * inset, y: end.y - unit.y * inset))

        color.setStroke()
        path.stroke()
    }

    private static func drawNode(at point: CGPoint, fill: NSColor?) {
        if let fill {
            drawCircle(center: point, radius: nodeRadius, fill: fill, stroke: nil)
        }
        drawCircle(
            center: point,
            radius: nodeRadius,
            fill: nil,
            stroke: (color: NSColor.black.withAlphaComponent(0.82), width: nodeStroke)
        )
    }

    private static func drawCircle(
        center: CGPoint,
        radius: CGFloat,
        fill: NSColor?,
        stroke: (color: NSColor, width: CGFloat)?
    ) {
        let rect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let path = NSBezierPath(ovalIn: rect)
        if let fill {
            fill.setFill()
            path.fill()
        }
        if let stroke {
            stroke.color.setStroke()
            path.lineWidth = stroke.width
            path.stroke()
        }
    }

    private static func lineColor(for state: ConnectionGlyphState) -> NSColor {
        switch state {
        case .idle: NSColor.black.withAlphaComponent(0.34)
        case .connected, .error: NSColor.black.withAlphaComponent(0.72)
        case .connecting: NSColor.black.withAlphaComponent(0.50)
        }
    }

    private static func statusColor(for state: ConnectionGlyphState) -> NSColor? {
        switch state {
        case .idle: nil
        case .connecting: .systemOrange
        case .connected: .systemGreen
        case .error: .systemRed
        }
    }
}
