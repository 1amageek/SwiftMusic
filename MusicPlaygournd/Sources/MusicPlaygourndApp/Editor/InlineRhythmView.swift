import AppKit
import MusicPlaygourndCore

/// A read-only result attached to a compiler-mapped source line.
@MainActor
final class InlineRhythmView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let lowLabel = NSTextField(labelWithString: "")
    private let highLabel = NSTextField(labelWithString: "")
    private var row: LoopRow?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [titleLabel, lowLabel, highLabel] {
            label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
            label.textColor = .secondaryLabelColor
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    private var events: [LoopEvent] = []
    private var beats = 4.0
    private var meter = 4
    private var beat = 0.0
    private var playing = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(row: LoopRow, events: [LoopEvent], beats: Double, meter: Int, beat: Double, playing: Bool) {
        self.row = row
        self.events = events
        self.beats = beats
        self.meter = meter
        self.beat = beat
        self.playing = playing
        titleLabel.stringValue = row.label
        let notes = events.compactMap(\.midiNote)
        let low = notes.min() ?? 0
        let high = notes.max() ?? low
        let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        lowLabel.stringValue = notes.isEmpty ? "" : "\(names[low % 12])\(low / 12 - 1)"
        highLabel.stringValue = high == low ? "" : "\(names[high % 12])\(high / 12 - 1)"
        needsLayout = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Inline rhythm, \(row.label), \(events.count) events, \(Int(beats)) beats")
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        titleLabel.frame = CGRect(x: 12, y: 5, width: max(1, bounds.width - 24), height: 16)
        let notes = events.compactMap(\.midiNote)
        let low = notes.min() ?? 0
        let high = notes.max() ?? low
        lowLabel.frame = CGRect(x: 12, y: 28 + CGFloat(high - low) * 55 / CGFloat(max(1, high - low + 1)), width: 32, height: 14)
        highLabel.frame = CGRect(x: 12, y: 28, width: 32, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard row != nil else { return }
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).fill()
        NSColor.white.withAlphaComponent(0.13).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).stroke()
        let plot = bounds.insetBy(dx: 12, dy: 0)
        let area = CGRect(x: plot.minX + 32, y: 28, width: max(1, plot.width - 32), height: 55)
        let scale = area.width / max(1, beats)
        let notes = events.compactMap(\.midiNote)
        let low = notes.min() ?? 0
        let high = notes.max() ?? low
        let lanes = max(1, high - low + 1)
        let laneHeight = area.height / CGFloat(lanes)
        for index in 0...Int(ceil(beats)) {
            let x = area.minX + CGFloat(index) * scale
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: area.minY))
            path.line(to: NSPoint(x: x, y: area.maxY))
            NSColor.white.withAlphaComponent(index % meter == 0 ? 0.16 : 0.06).setStroke()
            path.stroke()
        }
        for event in events {
            let active = playing && event.gain > 0 && event.isActive(at: beat, in: beats)
            let y = area.minY + CGFloat(high - (event.midiNote ?? high)) * laneHeight
            NSColor.systemMint.withAlphaComponent(active ? 1 : (event.gain > 0 ? 0.45 : 0.12)).setFill()
            event.forEachBeatRange(in: beats) { range in
                let rect = CGRect(x: area.minX + range.lowerBound * scale, y: y + 1,
                    width: max(2, (range.upperBound - range.lowerBound) * scale - 2), height: max(2, laneHeight - 2))
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            }
        }
        let cursor = NSBezierPath()
        let x = area.minX + beat * scale
        cursor.move(to: NSPoint(x: x, y: area.minY - 3))
        cursor.line(to: NSPoint(x: x, y: area.maxY + 3))
        NSColor.white.withAlphaComponent(playing ? 0.9 : 0.2).setStroke()
        cursor.stroke()
    }
}
