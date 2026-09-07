import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct CyclePatternRenderingTests {
    @Test(.timeLimit(.minutes(3)))
    func completeAlternationAndChordsReachPCMAndLexicalMetadata() throws {
        let compiler = SoundCompiler()
        let renderer = LoopRenderer()
        let loop = try renderer.render(compiler.compile(
            Synthesizer(.sine).notes("<C4,E4 [G4 G4]>")
        ), bpm: 120, beatsPerBar: 4)
        try loop.validate()
        #expect(loop.beatCount == 8)
        #expect(loop.events.map(\.midiNote) == [60, 64, 67, 67])
        #expect(loop.events.map(\.startBeat) == [0, 0, 4, 6])
        #expect(loop.events.map(\.durationBeats) == [4, 4, 2, 2])
        #expect(loop.events.map(\.patternStepIndex) == [0, 0, 1, 2])
        let secondCycle = try renderer.render(compiler.compile(
            Synthesizer(.sine).notes("G4 G4")
        ), bpm: 120, beatsPerBar: 4)
        #expect(Array(loop.samples.suffix(secondCycle.samples.count)) == secondCycle.samples)
        #expect(loop.samples.prefix(secondCycle.samples.count).contains { abs($0) > 0.01 })
    }

    @Test(.timeLimit(.minutes(3)))
    func closingAlternationDelimiterCannotCreatePhantomToken() throws {
        let samples = [Float](repeating: 0, count: 88_200)
        let row = LoopRow(sourceID: 0, label: "test", anchor: nil, peaks: [],
            patternText: "<C4 [E4 G4]>")
        let invalid = PreparedLoop(sampleRate: 44_100, bpm: 240, beatsPerBar: 4,
            beatCount: 4, samples: samples,
            events: [LoopEvent(sourceID: 0, label: "test", startBeat: 0,
                durationBeats: 1, midiNote: 60, velocity: 80, patternStepIndex: 3)], rows: [row])
        #expect {
            try invalid.validate()
        } throws: { error in
            error as? PreparedLoopValidationError == .invalidEvent(
                index: 0, reason: "pattern step index is outside pattern text")
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func oversizedNaturalPeriodFailsInsteadOfTruncatingAudio() throws {
        let compiled = try SoundCompiler().compile(
            Synthesizer(.sine).notes("<C4 D4 E4 F4 G4 A4 B4 C5 D5>")
        )
        #expect {
            try LoopRenderer().render(compiled, bpm: 120, beatsPerBar: 4)
        } throws: { error in
            error as? LoopRenderingError == .extentTooLong(36)
        }
    }
}
