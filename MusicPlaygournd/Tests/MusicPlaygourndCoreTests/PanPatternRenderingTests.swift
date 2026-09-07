import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct PanPatternRenderingTests {
    @Test(.timeLimit(.minutes(3)))
    func fractionalRatesChangeParametersWithoutRetimingNotes() throws {
        let pan: PanPattern = "-1 1"
        let gain: GainPattern = "1 0.5"
        let sound = Synthesizer(.sine).notes("C4 C4 C4 C4")
        let compiler = SoundCompiler()
        let renderer = LoopRenderer()
        let actual = try renderer.render(compiler.compile(
            sound.pan(pan.fast(1.5)).gain(gain.fast(1.5))
        ), bpm: 120, beatsPerBar: 4)
        let expected = try renderer.render(compiler.compile(
            sound.pan("-1 -1 1 -1").gain("1 1 0.5 1")
        ), bpm: 120, beatsPerBar: 4)
        #expect(actual.events.map(\.startBeat) == [0, 1, 2, 3])
        #expect(actual.events.map(\.pan) == [-1, -1, 1, -1])
        #expect(actual.events.map(\.gain) == [1, 1, 0.5, 1])
        #expect(actual.samples == expected.samples)
    }

    @Test(.timeLimit(.minutes(3)))
    func testPatternedPanAndGainReachStereoPCM() throws {
        let sound = Synthesizer(.sine).notes("C4 C4 C4 C4")
        let renderer = LoopRenderer()
        let plain = try renderer.render(SoundCompiler().compile(sound), bpm: 120, beatsPerBar: 4)
        let loop = try renderer.render(SoundCompiler().compile(
            sound.pan("-1 1 0 -1").gain("1 0.5 1 0")
        ), bpm: 120, beatsPerBar: 4)
        #expect(loop.events.map(\.pan) == [-1, 1, 0, -1])
        #expect(loop.events.map(\.gain) == [1, 0.5, 1, 0])
        #expect(plain.events.allSatisfy { $0.pan == nil })
        let leftGains: [Float] = [1, 0, sqrt(0.5), 0]
        let rightGains: [Float] = [0, 0.5, sqrt(0.5), 0]
        var maximumError: Float = 0
        for frame in 0..<(plain.samples.count / 2) {
            let beat = frame / 22_050
            maximumError = max(maximumError, abs(loop.samples[frame * 2] - plain.samples[frame * 2] * leftGains[beat]),
                abs(loop.samples[frame * 2 + 1] - plain.samples[frame * 2 + 1] * rightGains[beat]))
        }
        #expect(maximumError < 0.000_001)
        let centered = try renderer.render(SoundCompiler().compile(sound.pan("0")), bpm: 120, beatsPerBar: 4)
        let scalar = try renderer.render(SoundCompiler().compile(sound.pan(0)), bpm: 120, beatsPerBar: 4)
        #expect(centered.samples == scalar.samples)
    }

    @Test(.timeLimit(.minutes(3)))
    func testPanMetadataDecodesLegacyAndRejectsInvalidValues() throws {
        let legacy = Data(#"{"sourceID":0,"label":"test","startBeat":0,"durationBeats":1,"gain":1,"velocity":80}"#.utf8)
        #expect(try JSONDecoder().decode(LoopEvent.self, from: legacy).pan == nil)
        let valid = try LoopRenderer().render(SoundCompiler().compile(Sample("kick")), bpm: 120, beatsPerBar: 4)
        for pan in [2.0, Double.nan, Double.infinity] {
            let invalid = PreparedLoop(sampleRate: valid.sampleRate, bpm: valid.bpm,
                beatsPerBar: valid.beatsPerBar, beatCount: valid.beatCount, samples: valid.samples,
                events: [LoopEvent(sourceID: 0, label: "test", startBeat: 0, durationBeats: 1,
                    midiNote: nil, velocity: 80, pan: pan)], rows: valid.rows)
            #expect(throws: (any Error).self) { try invalid.validate() }
        }
    }
}
