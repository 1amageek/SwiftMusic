import AppKit
import MusicPlaygourndCore
import SwiftUI

/// Draws retained renderer trajectories without changing their timing or voice identity.
@MainActor
final class ControlTracePlot: NSView {
    var visualization: PreparedControlVisualization? {
        didSet { if oldValue != visualization { needsDisplay = true } }
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let visualization else { return }
        Self.draw(visualization, sourceID: nil, in: bounds.insetBy(dx: 8, dy: 8))
    }

    static func draw(_ value: PreparedControlVisualization, sourceID: Int?, in area: CGRect) {
        let traces = value.traces.lazy.filter { sourceID == nil || $0.sourceID == sourceID }
        let kinds: [PreparedControlTrace.Channel.Kind] = [.selectedValue, .amplitudeEnvelope, .pitchEnvelope, .filterEnvelope]
        let colors: [NSColor] = [.systemMint, .systemCyan, .systemOrange, .systemPurple]
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: area).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        for (index, kind) in kinds.enumerated() {
            let channels = traces.flatMap(\.channels).filter { $0.kind == kind }
            let low = channels.lazy.flatMap(\.points).map(\.value).min() ?? 0
            let high = channels.lazy.flatMap(\.points).map(\.value).max() ?? 1
            let span = max(1e-9, high - low)
            let path = NSBezierPath()
            for channel in channels {
                for pair in zip(channel.points, channel.points.dropFirst()) {
                    let cycle = floor(pair.0.beat / value.beatCount)
                    let start = pair.0.beat - cycle * value.beatCount
                    let end = min(value.beatCount, pair.1.beat - cycle * value.beatCount)
                    let y1 = high == low ? area.midY : area.maxY - (pair.0.value - low) / span * area.height
                    let y2 = high == low ? area.midY : area.maxY - (pair.1.value - low) / span * area.height
                    path.move(to: .init(x: area.minX + start / value.beatCount * area.width, y: y1))
                    path.line(to: .init(x: area.minX + end / value.beatCount * area.width, y: y2))
                }
            }
            colors[index].withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }
    }
}

struct ControlTraceResult: NSViewRepresentable {
    let visualization: PreparedControlVisualization
    func makeNSView(context: Context) -> ControlTracePlot { ControlTracePlot() }
    func updateNSView(_ view: ControlTracePlot, context: Context) {
        view.visualization = visualization
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("\(visualization.address.parameter) trajectories, \(visualization.traces.count) voices; selected value mint, amplitude cyan, pitch orange, filter purple; channels individually scaled")
    }
}
