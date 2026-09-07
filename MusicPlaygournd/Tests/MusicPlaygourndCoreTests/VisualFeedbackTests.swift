import Foundation
import MusicPlaygourndCore
import Testing

struct VisualFeedbackTests {
    @Test(.timeLimit(.minutes(3)))
    func alternationRetainsOneHighlightPerRepeatedOrSimultaneousLeaf() {
        let pattern = "<C4,E4 [G4*2 ~]>"
        let source = "// 🎵\n.notes(\"\(pattern)\")"
        let ranges = PlayingLiteral.tokenRanges(pattern: pattern, line: 2, source: source)
        #expect(ranges.map { (source as NSString).substring(with: $0) } == ["C4,E4", "G4*2", "~"])
    }

    @Test(.timeLimit(.minutes(3)))
    func testSourceAnchorsFollowUnicodeInsertionAndDropDeletedLine() {
        var source = "// 🎵\n.rhythm(\"x ~\")\n.notes(\"C2 G2\")"
        var map = SourceLineMap(source: source, lines: [2, 3])
        map.applyEdit(range: NSRange(location: 0, length: 0), replacement: "// new\n")
        source = "// new\n" + source
        #expect(map.currentLine(for: 2, in: source) == 3)
        let range = (source as NSString).range(of: ".rhythm(\"x ~\")\n")
        map.applyEdit(range: range, replacement: "")
        source = (source as NSString).replacingCharacters(in: range, with: "")
        #expect(map.currentLine(for: 2, in: source) == nil)
        #expect(map.currentLine(for: 3, in: source) == 3)
    }

    @Test(.timeLimit(.minutes(3)))
    func testNestedPatternHighlightsOnlyLeafTokens() {
        let source = ".rhythm(\"x [x [~ x]]\")"
        let tokens = PlayingLiteral.tokenRanges(pattern: "x [x [~ x]]", line: 1, source: source)
        #expect(tokens.map { (source as NSString).substring(with: $0) } == ["x", "x", "~", "x"])
    }

    @Test(.timeLimit(.minutes(3)))
    func testOnlyUniqueDirectPlainPlayingLiteralIsHighlighted() {
        let source = "// 🎵\n    Sample(\"kick\").rhythm(\"x x ~ x\")"
        let tokens = PlayingLiteral.tokenRanges(pattern: "x x ~ x", line: 2, source: source)
        #expect(tokens.map { (source as NSString).substring(with: $0) } == ["x", "x", "~", "x"])
        #expect(Set(tokens.map(\.location)).count == 4)
        let range = PlayingLiteral.range(pattern: "x x ~ x", line: 2, source: source)
        #expect(range.map { (source as NSString).substring(with: $0) } == "\"x x ~ x\"")
        for invalid in ["// .rhythm(\"x\")", ".rhythm(value)", ".rhythm(#\"x\"#)", ".rhythm(\"x\"); .rhythm(\"x\")"] {
            #expect(PlayingLiteral.range(pattern: "x", line: 1, source: invalid) == nil)
        }
        #expect(PlayingLiteral.range(pattern: "x x", line: 2, source: source) == nil)
    }

    @MainActor
    @Test(.timeLimit(.minutes(3)))
    func testCapturedSpectrumUsesDeviceSampleRateAndPausedSilence() throws {
        let analyzer = try SpectrumAnalyzer()
        let rate = 48_000.0
        let frequency = rate * 64 / Double(SpectrumAnalyzer.size)
        let samples = (0..<SpectrumAnalyzer.size).flatMap { frame -> [Float] in
            let value = Float(sin(Double(frame) * 2 * .pi * frequency / rate)) * 0.25
            return [value, -value]
        }
        let bands = analyzer.analyze(interleavedSamples: samples, sampleRate: rate, isPlaying: true)
        let peak = try #require(bands.indices.max { bands[$0] < bands[$1] })
        #expect(peak == Int(log(frequency / 20) / log(1000) * Double(SpectrumAnalyzer.bandCount)))
        #expect(abs((bands[peak]) - (-12.0412)) <= 0.1)
        #expect(analyzer.analyze(interleavedSamples: samples, sampleRate: rate, isPlaying: false).allSatisfy { $0 == -90 })
    }

    @MainActor
    @Test(.timeLimit(.minutes(3)))
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
        let peak = try #require(bands.indices.max { bands[$0] < bands[$1] })
        let expected = Int(log(frequency / 20) / log(1000) * Double(SpectrumAnalyzer.bandCount))
        #expect(peak == expected)
        #expect(abs((bands[peak]) - (-6.0206)) <= 0.1)
        #expect(analyzer.analyze(loop: loop, beat: 2, isPlaying: false).allSatisfy { $0 == -90 })
        #expect(analyzer.analyze(loop: loop, beat: 0, isPlaying: true).allSatisfy { $0.isFinite })
        let silence = PreparedLoop(sampleRate: sampleRate, bpm: 240, beatsPerBar: 4, beatCount: 4, samples: samples.map { _ in 0 }, events: [])
        #expect(analyzer.analyze(loop: silence, beat: 1, isPlaying: true).allSatisfy { $0 == -90 })
    }
}
