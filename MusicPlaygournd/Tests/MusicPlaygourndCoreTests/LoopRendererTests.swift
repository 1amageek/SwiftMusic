import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct LoopRendererTests {
    private let renderer = LoopRenderer()

    @Test(.timeLimit(.minutes(3)))
    func testSynthesisProducesFinitePCMAndTrackEvents() throws {
        struct Session: Sound {
            var body: some Sound {
                Track("lead") {
                    Synthesizer(.sine).notes("C4 E4 G4")
                }
            }
        }

        let sound = try SoundCompiler().compile(Session())
        let loop = try renderer.render(sound, bpm: 120, beatsPerBar: 4)

        #expect(loop.sampleRate == 44_100)
        #expect(loop.beatCount == 4)
        #expect(loop.samples.count == 176_400)
        #expect(!(loop.samples.contains { !$0.isFinite }))
        #expect(loop.samples.map { abs($0) }.max() ?? 0 > 0.01)
        #expect(loop.events.map(\.label) == ["lead", "lead", "lead"])
        #expect(loop.events.map(\.midiNote) == [60, 64, 67])
        #expect(loop.events.map(\.durationBeats) == [4.0 / 3.0, 4.0 / 3.0, 4.0 / 3.0])
        #expect(loop.rows.count == 1)
        #expect(loop.rows[0].sourceID == 0)
        #expect(loop.rows[0].label == "lead")
        #expect(loop.rows[0].patternText == "C4 E4 G4")
        #expect(!(loop.rows[0].peaks.allSatisfy { $0 == 0 }))
        #expect(loop.rows[0].peaks.count <= PreparedLoop.maximumPeakBins)
    }

    @Test(.timeLimit(.minutes(3)))
    func testNestedGainPatternChangesActualVoicePCM() throws {
        let sound = Synthesizer(.sine).notes("C4 [C4 C4] C4 C4").gain("1 [0 0.5] 0.25 0.75")
        let loop = try renderer.render(SoundCompiler().compile(sound), bpm: 120, beatsPerBar: 4)
        #expect(loop.events.map(\.startBeat) == [0, 1, 1.5, 2, 3])
        #expect(loop.events.map(\.gain) == [1, 0, 0.5, 0.25, 0.75])
        #expect(loop.events.map(\.patternStepIndex) == [0, 1, 2, 3, 4])
        func peak(_ start: Double, _ end: Double) -> Float {
            let lower = Int(start * 22050) * 2
            let upper = Int(end * 22050) * 2
            return loop.samples[lower..<upper].reduce(0) { max($0, abs($1)) }
        }
        let full = peak(0, 1)
        #expect(full > 0.1)
        #expect(peak(1, 1.5) == 0)
        #expect(abs((peak(1.5, 2)) - (full * 0.5)) <= 0.001)
        #expect(abs((peak(2, 3)) - (full * 0.25)) <= 0.001)
        #expect(abs((peak(3, 4)) - (full * 0.75)) <= 0.001)
    }

    @Test(.timeLimit(.minutes(3)))
    func testGainPanAndMuteChangeAudiblePCM() throws {
        let plainSound = Synthesizer(.sine).notes("C4")
        let plain = try renderer.render(
            SoundCompiler().compile(plainSound), bpm: 120, beatsPerBar: 4
        )
        let gained = try renderer.render(
            SoundCompiler().compile(plainSound.gain(0.5)), bpm: 120, beatsPerBar: 4
        )
        let panned = try renderer.render(
            SoundCompiler().compile(plainSound.pan(-1)), bpm: 120, beatsPerBar: 4
        )
        let muted = try renderer.render(
            SoundCompiler().compile(plainSound.muted()), bpm: 120, beatsPerBar: 4
        )

        let plainPeak = plain.samples.map { abs($0) }.max() ?? 0
        let gainedPeak = gained.samples.map { abs($0) }.max() ?? 0
        #expect(abs((gainedPeak) - (plainPeak * 0.5)) <= 0.01)
        #expect(panned.samples.enumerated().filter { $0.offset.isMultiple(of: 2) }.map { abs($0.element) }.max() ?? 0 > 0.01)
        #expect(abs((panned.samples.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map { abs($0.element) }.max() ?? 0) - (0)) <= 0.000_001)
        #expect(muted.samples.allSatisfy { $0 == 0 })
    }

    @Test(.timeLimit(.minutes(3)))
    func testUnsupportedSourceSettingsAndRoutingFailExplicitly() throws {
        let routed = try SoundCompiler().compile(Sample("kick").output("external"))
        #expect {
            try renderer.render(routed, bpm: 120, beatsPerBar: 4)
        } throws: { error in
            if case .unsupportedRenderNode(_, "external output external") = error as? LoopRenderingError { return true }
            return false
        }

        let region = try SampleRegion(startFraction: 0.1, endFraction: 0.9)
        #expect {
            try SoundCompiler().compile(Sample("kick").sampleRegion(region))
        } throws: { error in
            if case .unsupportedSourceSetting = error as? SoundCompilationError { return true }
            return false
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testInvalidTempoAndBoundsFailBeforeRendering() throws {
        let sound = try SoundCompiler().compile(Synthesizer(.sine))
        #expect {
            try renderer.render(sound, bpm: 39, beatsPerBar: 4)
        } throws: { error in
            error as? LoopRenderingError == .invalidBPM(39)
        }
        #expect {
            try renderer.render(sound, bpm: 120, beatsPerBar: 1)
        } throws: { error in
            error as? LoopRenderingError == .invalidMeter(1)
        }

        let oversized = try SoundCompiler().compile(Synthesizer(.sine).repeated(33).slow(16))
        #expect {
            try renderer.render(oversized, bpm: 120, beatsPerBar: 4)
        } throws: { error in
            if case .extentTooLong = error as? LoopRenderingError { return true }
            return false
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testGatedEventVisualDurationMatchesAudibleDuration() throws {
        let sound = try SoundCompiler().compile(Synthesizer(.sine).gate(0.5))
        let loop = try renderer.render(sound, bpm: 120, beatsPerBar: 4)
        #expect(loop.events.count == 1)
        #expect(abs((loop.events[0].durationBeats) - (0.5)) <= 0.000_001)
    }

    @Test(.timeLimit(.minutes(3)))
    func testLoopEventsCarryPatternStepIndices() throws {
        let rhythm = try renderer.render(
            SoundCompiler().compile(Synthesizer(.sine).rhythm("x ~ x")),
            bpm: 120,
            beatsPerBar: 4
        )
        #expect(rhythm.events.map(\.patternStepIndex) == [0, 2])

        let notes = try renderer.render(
            SoundCompiler().compile(Synthesizer(.sine).notes("C4 ~ G4")),
            bpm: 120,
            beatsPerBar: 4
        )
        #expect(notes.events.map(\.patternStepIndex) == [0, 2])
    }

    @Test(.timeLimit(.minutes(3)))
    func testRowsRetainSilentSourcesAndPreMixPeaks() throws {
        struct Session: Sound {
            var body: some Sound {
                Track("rest") {
                    Sample("kick").rhythm(
                        "~ ~",
                        fileID: "Session.swift",
                        line: 12,
                        column: 17
                    )
                }
                Track("muted") {
                    Synthesizer(.sine)
                        .rhythm("x ~", fileID: "Session.swift", line: 20, column: 17)
                        .muted()
                }
            }
        }

        let sound = try SoundCompiler().compile(Session())
        let loop = try renderer.render(sound, bpm: 120, beatsPerBar: 4)

        #expect(loop.rows.map(\.label) == ["kick", "muted"])
        #expect(loop.rows.map(\.sourceID) == [0, 1])
        #expect(loop.rows[0].anchor == SoundSourceAnchor(fileID: "Session.swift", line: 12, column: 17))
        #expect(loop.rows[0].patternText == "~ ~")
        #expect(loop.rows[0].peaks.allSatisfy { $0 == 0 })
        #expect(!(loop.rows[1].peaks.allSatisfy { $0 == 0 }))
        #expect(loop.samples.allSatisfy { $0 == 0 })
    }
}
