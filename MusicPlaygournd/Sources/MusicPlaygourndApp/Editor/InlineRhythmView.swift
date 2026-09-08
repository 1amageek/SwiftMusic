import AppKit
import MusicPlaygourndCore

/// A read-only result attached to a compiler-mapped source line.
@MainActor
final class InlineRhythmView: NSView {
    static let height: CGFloat = 48
    static let spacing: CGFloat = 4

    private let titleLabel = NSTextField(labelWithString: "")
    private let lowLabel = NSTextField(labelWithString: "")
    private let highLabel = NSTextField(labelWithString: "")
    private let muteButton = NSButton()
    private var row: LoopRow?
    private var trackID: Int?
    private var isMuted: Bool?
    private var onToggleTrackMute: (Int) -> Void = { _ in }
    private var visualization: PreparedControlVisualization?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [titleLabel, lowLabel, highLabel] {
            label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
            label.textColor = .secondaryLabelColor
            addSubview(label)
        }
        lowLabel.font = .monospacedSystemFont(ofSize: 8, weight: .medium)
        highLabel.font = lowLabel.font
        configureMuteButton()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureMuteButton()
    }

    private func configureMuteButton() {
        muteButton.isBordered = false
        muteButton.setButtonType(.momentaryPushIn)
        muteButton.imagePosition = .imageOnly
        muteButton.imageScaling = .scaleProportionallyDown
        muteButton.focusRingType = .none
        muteButton.target = self
        muteButton.action = #selector(toggleMute(_:))
        muteButton.setAccessibilityElement(true)
        muteButton.setAccessibilityRole(.button)
        muteButton.isHidden = true
        muteButton.isEnabled = false
        addSubview(muteButton)
    }

    private var events: [LoopEvent] = []
    private var beats = 4.0
    private var meter = 4
    private var beat = 0.0
    private var playing = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !muteButton.isHidden, muteButton.isEnabled else { return nil }
        guard let superview else { return nil }
        let localPoint = convert(point, from: superview)
        let buttonPoint = muteButton.convert(localPoint, from: self)
        return muteButton.bounds.contains(buttonPoint) ? muteButton : nil
    }

    func update(row: LoopRow, events: [LoopEvent], beats: Double, meter: Int, beat: Double, playing: Bool,
                trackID: Int? = nil, isMuted: Bool? = nil,
                onToggleTrackMute: @escaping (Int) -> Void = { _ in },
                visualization: PreparedControlVisualization? = nil) {
        self.visualization = visualization
        self.row = row
        self.trackID = trackID
        self.isMuted = isMuted
        self.onToggleTrackMute = onToggleTrackMute
        self.events = events
        self.beats = beats
        self.meter = meter
        self.beat = beat
        self.playing = playing
        titleLabel.stringValue = row.label
        if let visualization, visualization.address.target == .source(row.sourceID) {
            titleLabel.stringValue += " · \(visualization.address.parameter)"
        }
        let limitations = Set(events.filter { if case .unsupported = $0.midiProjection { return true }; return false }.map(\.pitchDescription))
        if !limitations.isEmpty { titleLabel.stringValue += " · " + limitations.sorted().joined(separator: ", ") }
        toolTip = events.map(\.eventDescription).joined(separator: "\n")
        let notes = events.compactMap(\.displayedMIDINote)
        let low = notes.min() ?? 0
        let high = notes.max() ?? low
        let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        lowLabel.stringValue = notes.isEmpty ? "" : "\(names[low % 12])\(low / 12 - 1)"
        highLabel.stringValue = high == low ? "" : "\(names[high % 12])\(high / 12 - 1)"
        let muteAvailable = trackID != nil && isMuted != nil
        muteButton.isHidden = trackID == nil
        muteButton.isEnabled = muteAvailable
        if let isMuted, muteAvailable {
            let symbol = isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            let label = isMuted ? "Unmute track \(row.label)" : "Mute track \(row.label)"
            muteButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            muteButton.contentTintColor = isMuted ? .systemOrange : .secondaryLabelColor
            muteButton.toolTip = label
            muteButton.setAccessibilityLabel(label)
            muteButton.setAccessibilityValue(isMuted ? "Muted" : "Unmuted")
            muteButton.setAccessibilityElement(true)
        } else if trackID != nil {
            muteButton.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Mute unavailable")
            muteButton.contentTintColor = .tertiaryLabelColor
            muteButton.toolTip = "Mute unavailable for \(row.label)"
            muteButton.setAccessibilityLabel("Mute unavailable for \(row.label)")
            muteButton.setAccessibilityValue("Unavailable")
            muteButton.setAccessibilityElement(true)
        } else {
            muteButton.image = nil
            muteButton.toolTip = nil
            muteButton.setAccessibilityElement(false)
        }
        needsLayout = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Inline rhythm, \(row.label), \(events.count) events, \(Int(beats)) beats")
        needsDisplay = true
    }

    @objc private func toggleMute(_ sender: NSButton) {
        guard sender === muteButton, let trackID, isMuted != nil, !muteButton.isHidden, muteButton.isEnabled else { return }
        onToggleTrackMute(trackID)
    }

    override func layout() {
        super.layout()
        let buttonWidth: CGFloat = 22
        let buttonInset: CGFloat = 8
        muteButton.frame = CGRect(x: buttonInset, y: 3,
                                  width: buttonWidth, height: 20)
        let titleLeading = muteButton.isHidden ? 12 : buttonWidth + buttonInset + 4
        titleLabel.frame = CGRect(x: titleLeading, y: 5, width: max(1, bounds.width - titleLeading - 12), height: 16)
        let notes = events.compactMap(\.displayedMIDINote)
        let low = notes.min() ?? 0
        let high = notes.max() ?? low
        lowLabel.frame = CGRect(x: 12, y: 24 + CGFloat(high - low) * 18 / CGFloat(max(1, high - low + 1)) - 4, width: 32, height: 9)
        highLabel.frame = CGRect(x: 12, y: 20, width: 32, height: 9)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard row != nil else { return }
        NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).fill()
        NSColor.white.withAlphaComponent(0.07).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).stroke()
        let plot = bounds.insetBy(dx: 12, dy: 0)
        let area = CGRect(x: plot.minX + 32, y: 24, width: max(1, plot.width - 32), height: 18)
        let scale = area.width / max(1, beats)
        let notes = events.compactMap(\.displayedMIDINote)
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
            let y = area.minY + CGFloat(high - (event.displayedMIDINote ?? high)) * laneHeight
            NSColor.systemMint.withAlphaComponent(active ? 1 : (event.gain > 0 ? 0.45 : 0.12)).setFill()
            event.forEachBeatRange(in: beats) { range in
                let rect = CGRect(x: area.minX + range.lowerBound * scale, y: y + 1,
                    width: max(2, (range.upperBound - range.lowerBound) * scale - 2), height: max(2, laneHeight - 2))
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            }
        }
        if let visualization, let row, visualization.address.target == .source(row.sourceID) {
            ControlTracePlot.draw(visualization, sourceID: row.sourceID, in: area)
        }
        let cursor = NSBezierPath()
        let x = area.minX + beat * scale
        cursor.move(to: NSPoint(x: x, y: area.minY - 3))
        cursor.line(to: NSPoint(x: x, y: area.maxY + 3))
        NSColor.white.withAlphaComponent(playing ? 0.9 : 0.2).setStroke()
        cursor.stroke()
    }
}
