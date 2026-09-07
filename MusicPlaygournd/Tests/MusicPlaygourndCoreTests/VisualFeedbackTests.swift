import Foundation
import MusicPlaygourndCore
import XCTest

final class VisualFeedbackTests: XCTestCase {
    func testSourceAnchorsFollowUnicodeInsertionAndDropDeletedLine() {
        var source = "// 🎵\n.rhythm(\"x ~\")\n.notes(\"C2 G2\")"
        var map = SourceLineMap(source: source, lines: [2, 3])
        map.applyEdit(range: NSRange(location: 0, length: 0), replacement: "// new\n")
        source = "// new\n" + source
        XCTAssertEqual(map.currentLine(for: 2, in: source), 3)
        let range = (source as NSString).range(of: ".rhythm(\"x ~\")\n")
        map.applyEdit(range: range, replacement: "")
        source = (source as NSString).replacingCharacters(in: range, with: "")
        XCTAssertNil(map.currentLine(for: 2, in: source))
        XCTAssertEqual(map.currentLine(for: 3, in: source), 3)
    }

    func testNestedPatternHighlightsOnlyLeafTokens() {
        let source = ".rhythm(\"x [x [~ x]]\")"
        let tokens = PlayingLiteral.tokenRanges(pattern: "x [x [~ x]]", line: 1, source: source)
        XCTAssertEqual(tokens.map { (source as NSString).substring(with: $0) }, ["x", "x", "~", "x"])
    }

    func testOnlyUniqueDirectPlainPlayingLiteralIsHighlighted() {
        let source = "// 🎵\n    Sample(\"kick\").rhythm(\"x x ~ x\")"
        let tokens = PlayingLiteral.tokenRanges(pattern: "x x ~ x", line: 2, source: source)
        XCTAssertEqual(tokens.map { (source as NSString).substring(with: $0) }, ["x", "x", "~", "x"])
        XCTAssertEqual(Set(tokens.map(\.location)).count, 4)
        let range = PlayingLiteral.range(pattern: "x x ~ x", line: 2, source: source)
        XCTAssertEqual(range.map { (source as NSString).substring(with: $0) }, "\"x x ~ x\"")
        for invalid in ["// .rhythm(\"x\")", ".rhythm(value)", ".rhythm(#\"x\"#)", ".rhythm(\"x\"); .rhythm(\"x\")"] {
            XCTAssertNil(PlayingLiteral.range(pattern: "x", line: 1, source: invalid))
        }
        XCTAssertNil(PlayingLiteral.range(pattern: "x x", line: 2, source: source))
    }

    @MainActor
    func testSpectrumMeasuresPCMFrequencyLevelStereoAndSilence() throws {
        let analyzer = try SpectrumAnalyzer()
        let sampleRate = PreparedLoop.requiredSampleRate
        let frequency = sampleRate * 32 / Double(SpectrumAnalyzer.size)
        let samples = (0..<44100).flatMap { frame -> [Float] in
            let value = Float(sin(Double(frame) * 2 * .pi * frequency / sampleRate)) * 0.5
            return [value, -value]
        }
        let loop = PreparedLoop(sampleRate: sampleRate, bpm: 240, beatsPerBar: 4, beatCount: 4, samples: samples, events: [])
        try loop.validate()
        let bands = analyzer.analyze(loop: loop, beat: 2, isPlaying: true)
        let peak = try XCTUnwrap(bands.indices.max { bands[$0] < bands[$1] })
        let expected = Int(log(frequency / 20) / log(1000) * Double(SpectrumAnalyzer.bandCount))
        XCTAssertEqual(peak, expected)
        XCTAssertEqual(bands[peak], -6.0206, accuracy: 0.1)
        XCTAssertTrue(analyzer.analyze(loop: loop, beat: 2, isPlaying: false).allSatisfy { $0 == -90 })
        XCTAssertTrue(analyzer.analyze(loop: loop, beat: 0, isPlaying: true).allSatisfy { $0.isFinite })
        let silence = PreparedLoop(sampleRate: sampleRate, bpm: 240, beatsPerBar: 4, beatCount: 4, samples: samples.map { _ in 0 }, events: [])
        XCTAssertTrue(analyzer.analyze(loop: silence, beat: 1, isPlaying: true).allSatisfy { $0 == -90 })
    }
}
