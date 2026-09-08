import AppKit
import MusicPlaygourndCore

/// Reserves visual result space without adding characters or text attributes.
@MainActor
final class InlineRhythmLayout: NSObject, @MainActor NSLayoutManagerDelegate {
    private weak var editor: NSTextView?
    private var source = ""
    private var anchors: [Int: Int] = [:]
    private var endings: [Int: CGFloat] = [:]
    private var lineEnds: [Int: Int] = [:]
    private var cards: [Int: InlineRhythmView] = [:]
    private(set) var cardFrames: [Int: CGRect] = [:]

    init(editor: NSTextView) {
        self.editor = editor
        super.init()
        editor.layoutManager?.delegate = self
    }

    func update(loop: PreparedLoop?, rowLines: [Int: Int], enabled: Bool, beat: Double, isPlaying: Bool,
                mutedTracks: [Int: Bool] = [:], onToggleTrackMute: @escaping (Int) -> Void = { _ in },
                visualization: PreparedControlVisualization? = nil) {
        guard let editor, let manager = editor.layoutManager else { return }
        let rows = enabled ? (loop?.rows ?? []) : []
        let mapped = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            rowLines[row.sourceID].map { (row.sourceID, $0) }
        })
        if source != editor.string || anchors != mapped {
            source = editor.string
            anchors = mapped
            endings = [:]
            lineEnds = [:]
            let text = source as NSString
            var offset = 0
            var line = 1
            while offset < text.length {
                let range = text.lineRange(for: NSRange(location: offset, length: 0))
                let count = mapped.values.filter { $0 == line }.count
                if count > 0 {
                    let end = NSMaxRange(range) - 1
                    endings[end] = CGFloat(count) * (InlineRhythmView.height + InlineRhythmView.spacing)
                    lineEnds[line] = end
                }
                offset = NSMaxRange(range)
                line += 1
            }
            manager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: text.length), actualCharacterRange: nil)
        }
        for id in Array(cards.keys) where mapped[id] == nil {
            cards.removeValue(forKey: id)?.removeFromSuperview()
        }
        if let loop {
            for row in rows where mapped[row.sourceID] != nil {
                let card = cards[row.sourceID] ?? InlineRhythmView()
                if card.superview == nil { editor.addSubview(card) }
                cards[row.sourceID] = card
                card.update(row: row, events: loop.events.filter { $0.sourceID == row.sourceID },
                    beats: loop.beatCount, meter: loop.beatsPerBar, beat: beat, playing: isPlaying,
                    trackID: row.trackID, isMuted: row.trackID.flatMap { mutedTracks[$0] },
                    onToggleTrackMute: onToggleTrackMute, visualization: visualization)
            }
        }
        editor.setAccessibilityChildren(cards.keys.sorted().compactMap { cards[$0] })
        layoutCards()
    }

    func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingAfterGlyphAt glyphIndex: Int,
                       withProposedLineFragmentRect rect: NSRect) -> CGFloat {
        endings[layoutManager.characterIndexForGlyph(at: glyphIndex)] ?? 0
    }

    func layoutCards() {
        guard let editor, let manager = editor.layoutManager, let container = editor.textContainer else { return }
        manager.ensureLayout(for: container)
        cardFrames = [:]
        let origin = editor.textContainerOrigin
        let width = max(160, (editor.enclosingScrollView?.contentView.bounds.width ?? editor.bounds.width) - origin.x * 2)
        for (line, end) in lineEnds {
            guard end < (editor.string as NSString).length else { continue }
            let glyph = manager.glyphIndexForCharacter(at: end)
            let rect = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            for (index, id) in anchors.keys.filter({ anchors[$0] == line }).sorted().enumerated() {
                let frame = CGRect(x: origin.x, y: origin.y + rect.maxY + InlineRhythmView.spacing + CGFloat(index) * (InlineRhythmView.height + InlineRhythmView.spacing),
                                   width: width, height: InlineRhythmView.height)
                cards[id]?.frame = frame
                cardFrames[id] = frame
            }
        }
        let bottom = max(manager.usedRect(for: container).maxY + origin.y * 2,
                         (cardFrames.values.map(\.maxY).max() ?? 0) + origin.y)
        let height = max(editor.enclosingScrollView?.contentSize.height ?? 0, bottom)
        if abs(editor.frame.height - height) > 0.5 { editor.setFrameSize(NSSize(width: editor.frame.width, height: height)) }
    }
}
