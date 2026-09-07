import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct TypedParameterRenderingTests {
    @Test(.timeLimit(.minutes(3)))
    func patternedDSPReachesPCMAndZeroPitchPreservesPCM() throws {
        let compiler = SoundCompiler()
        let renderer = LoopRenderer()
        let sound = Synthesizer(.sine).notes("C4 C4")
        let envelope = try Envelope(attack: .milliseconds(5), decay: .milliseconds(20),
                                    sustainLevel: 0.5, release: .zero)
        let patterns = try EnvelopePattern(steps: [envelope])
        let actual = try renderer.render(compiler.compile(sound.transpose(PitchPattern("0.5"))
            .lowPass("400").envelope(patterns)), bpm: 120, beatsPerBar: 4)
        let expected = try renderer.render(compiler.compile(sound.transpose(PitchPattern("0.5"))
            .lowPass(Frequency(hertz: 400)).envelope(envelope)), bpm: 120, beatsPerBar: 4)
        #expect(actual.samples == expected.samples)
        #expect(actual.samples.contains { $0 != 0 })
        let plain = try renderer.render(compiler.compile(sound), bpm: 120, beatsPerBar: 4)
        let zero = try renderer.render(compiler.compile(sound.transpose(PitchPattern("0"))),
                                       bpm: 120, beatsPerBar: 4)
        #expect(plain.samples == zero.samples)
        #expect(plain.events == zero.events)
    }
}
