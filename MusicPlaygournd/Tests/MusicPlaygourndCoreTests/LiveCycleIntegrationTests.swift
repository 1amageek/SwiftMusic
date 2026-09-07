import AppKit
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore
@testable import MusicPlaygourndApp

extension NativeHostTests {
    @MainActor
    struct LiveCycleIntegrationTests {
        @Test(.timeLimit(.minutes(3)))
        func compiledCrossingVoiceSurvivesNativeWrapsAndInlinePresentation() throws {
            let source = """
            Synthesizer(.sine)
                .notes("C4")
                .offset(.half)
                .offset(.quarter)
            """
            let sound = Synthesizer(.sine)
                .notes("C4", fileID: "Session.swift", line: 2, column: 5)
                .offset(.half)
                .offset(.quarter)
            let compiled = try SoundCompiler().compile(sound, liveLoop: LiveLoopPolicy(
                beatsPerBar: 4, maximumBeats: .whole))
            let loop = try LoopRenderer().render(compiled, bpm: 240, beatsPerBar: 4)
            let event = try #require(loop.events.first)
            let row = try #require(loop.rows.first)
            #expect(loop.events.count == 1)
            #expect(event.startBeat == 3 && event.durationBeats == 4 && event.wrapsLoopBoundary)

            let engine = try AudioLoopEngine()
            defer { engine.stop() }
            engine.beginUpdate(revision: 23)
            try engine.submit(loop: loop, revision: 23)
            try engine.prepareOfflineRenderingForTests()
            try engine.play()
            var previousBeat = engine.snapshot().beatPosition
            var wraps = 0
            let blocks = (loop.samples.count / 2 * 3 + 4095) / 4096
            for _ in 0..<blocks {
                let output = try engine.renderOfflineForTests(frameCount: 4096)
                let allFinite = output.allSatisfy { $0.isFinite }
                #expect(allFinite)
                #expect(output.contains { abs($0) > 0.01 })
                let snapshot = engine.snapshot()
                #expect(snapshot.revision == 23 && snapshot.isPlaying)
                #expect(event.isActive(at: snapshot.beatPosition, in: loop.beatCount))
                if snapshot.beatPosition < previousBeat { wraps += 1 }
                previousBeat = snapshot.beatPosition
            }
            #expect(wraps >= 2)
            #expect(engine.outputMeter().interleavedSamples.contains { abs($0) > 0.01 })

            let pattern = try #require(row.patternText)
            let anchor = try #require(row.anchor)
            let ranges = PlayingLiteral.tokenRanges(pattern: pattern, line: anchor.line, source: source)
            let token = try #require(event.patternStepIndex)
            #expect(ranges.count == 1 && token == 0)
            #expect((source as NSString).substring(with: ranges[token]) == "C4")

            let editor = CompletionTextView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
            editor.isRichText = false
            editor.allowsUndo = true
            editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            editor.string = source
            editor.setSelectedRange(ranges[token])
            let selection = editor.selectedRange()
            let undoBefore = editor.undoManager?.canUndo
            let presentation = InlineRhythmLayout(editor: editor)
            func colors(at beat: Double, playing: Bool) throws -> [NSColor] {
                presentation.update(loop: loop, rowLines: [0: 4], enabled: true,
                                    beat: beat, isPlaying: playing)
                let card = try #require(editor.subviews.compactMap { $0 as? InlineRhythmView }.first)
                card.layoutSubtreeIfNeeded()
                let bitmap = try #require(card.bitmapImageRepForCachingDisplay(in: card.bounds))
                card.cacheDisplay(in: card.bounds, to: bitmap)
                return try [0.25, 0.875].map { fraction in
                    let color = try #require(bitmap.colorAt(
                        x: Int(Double(bitmap.pixelsWide) * fraction), y: bitmap.pixelsHigh / 2))
                    return try #require(color.usingColorSpace(.deviceRGB))
                }
            }
            let stopped = try colors(at: 0, playing: false)
            for beat in [3.99, 0.01] {
                #expect(event.isActive(at: beat, in: loop.beatCount))
                let active = try colors(at: beat, playing: true)
                #expect(zip(active, stopped).allSatisfy {
                    $0.greenComponent > $1.greenComponent + 0.1
                })
                #expect(editor.string == source)
                #expect(editor.selectedRange() == selection)
                #expect(editor.undoManager?.canUndo == undoBefore)
                #expect(PlayingLiteral.tokenRanges(pattern: pattern, line: anchor.line,
                                                   source: editor.string) == ranges)
            }
        }
    }
}
