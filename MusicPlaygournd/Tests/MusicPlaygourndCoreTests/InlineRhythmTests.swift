import AppKit
import MusicPlaygourndCore
import XCTest
@testable import MusicPlaygourndApp

@MainActor
final class InlineRhythmTests: XCTestCase {
    func testViewportAlignmentIncludesDocumentFrameAndBounds() {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 200))
        let editor = CompletionTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 800))
        scroll.documentView = editor
        editor.setFrameOrigin(CGPoint(x: 0, y: 80))
        editor.setBoundsOrigin(CGPoint(x: 0, y: 30))
        scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: 100))
        let rect = CodeEditor.viewportRect(CGRect(x: 0, y: 200, width: 100, height: 20), editor: editor, scroll: scroll)
        let expected = 200 + editor.textContainerOrigin.y + editor.frame.minY - editor.bounds.minY - scroll.contentView.bounds.minY
        XCTAssertEqual(rect.minY, expected, accuracy: 0.1)
        XCTAssertNotEqual(rect.minY, 200 + editor.textContainerOrigin.y - scroll.contentView.bounds.minY)
    }

    func testInlineSpacingPreservesSourceSelectionUndoAndRemaps() throws {
        let editor = CompletionTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.string = "Sample(\"kick\").rhythm(\"x ~\")\n.gain(0.5)\n"
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        let source = editor.string
        let manager = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        manager.ensureLayout(for: container)
        let secondOffset = (source as NSString).range(of: ".gain").location
        func secondY() -> CGFloat {
            manager.ensureLayout(for: container)
            return manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: secondOffset), effectiveRange: nil).minY + editor.textContainerOrigin.y
        }
        let baseline = secondY()
        let presentation = InlineRhythmLayout(editor: editor)
        let loop = PreparedLoop(sampleRate: 44_100, bpm: 120, beatsPerBar: 4, beatCount: 4,
            samples: [], events: [], rows: [
                LoopRow(sourceID: 0, label: "Kick", anchor: nil, peaks: []),
                LoopRow(sourceID: 1, label: "Hat", anchor: nil, peaks: [])
            ])
        let undoBefore = editor.undoManager?.canUndo
        presentation.update(loop: loop, rowLines: [0: 1, 1: 1], enabled: true, beat: 0, isPlaying: false)
        let card = try XCTUnwrap(editor.subviews.compactMap { $0 as? InlineRhythmView }.first)
        card.layoutSubtreeIfNeeded()
        let title = try XCTUnwrap(card.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertGreaterThan(title.frame.width, 100)
        let bitmap = try XCTUnwrap(card.bitmapImageRepForCachingDisplay(in: card.bounds))
        card.cacheDisplay(in: card.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        let first = try XCTUnwrap(presentation.cardFrames[0])
        let other = try XCTUnwrap(presentation.cardFrames[1])
        XCTAssertGreaterThanOrEqual(first.minY, editor.textContainerOrigin.y + 14)
        XCTAssertGreaterThan(other.minY, first.maxY)
        XCTAssertGreaterThanOrEqual(secondY(), other.maxY)
        XCTAssertEqual(editor.string, source)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertEqual(editor.undoManager?.canUndo, undoBefore)
        presentation.update(loop: loop, rowLines: [0: 1, 1: 1], enabled: false, beat: 1, isPlaying: true)
        XCTAssertTrue(presentation.cardFrames.isEmpty)
        XCTAssertEqual(secondY(), baseline, accuracy: 0.1)
        presentation.update(loop: loop, rowLines: [0: 2], enabled: true, beat: 2, isPlaying: true)
        XCTAssertGreaterThan(try XCTUnwrap(presentation.cardFrames[0]).minY, baseline)
        XCTAssertNil(presentation.cardFrames[1])
        XCTAssertEqual(editor.string, source)
    }
}
