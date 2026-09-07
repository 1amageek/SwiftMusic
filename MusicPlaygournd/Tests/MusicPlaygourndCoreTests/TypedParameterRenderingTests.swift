import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct TypedParameterRenderingTests {
    @Test(.timeLimit(.minutes(3)))
    func unavailableDSPFailsExplicitlyAndZeroPitchPreservesPCM() throws {
        let compiler = SoundCompiler()
        let renderer = LoopRenderer()
        let sound = Synthesizer(.sine).notes("C4 C4")
        let envelope = try Envelope(attack: .milliseconds(5), decay: .milliseconds(20),
                                    sustainLevel: 0.5, release: .milliseconds(40))
        let patterns = try EnvelopePattern(steps: [envelope])
        let cases: [(ModifiedSound, LoopRenderingError)] = [
            (sound.transpose(PitchPattern("0.5")), .unsupportedEventSetting(index: 0, setting: "pitchOffsetSemitones")),
            (sound.lowPass("400"), .unsupportedEventSetting(index: 0, setting: "cutoffHz")),
            (sound.envelope(patterns), .unsupportedEventSetting(index: 0, setting: "envelope")),
            (Synthesizer(.sine).rhythm("~").lowPass("400"), .unsupportedSourceSetting(sourceID: 0, setting: "filter"))
        ]
        for (declaration, error) in cases {
            #expect(throws: error) {
                try renderer.render(compiler.compile(declaration), bpm: 120, beatsPerBar: 4)
            }
        }
        let plain = try renderer.render(compiler.compile(sound), bpm: 120, beatsPerBar: 4)
        let zero = try renderer.render(compiler.compile(sound.transpose(PitchPattern("0"))),
                                       bpm: 120, beatsPerBar: 4)
        #expect(plain.samples == zero.samples)
        #expect(plain.events == zero.events)
    }
}
