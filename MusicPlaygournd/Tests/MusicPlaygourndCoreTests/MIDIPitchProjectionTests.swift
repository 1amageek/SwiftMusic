import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct MIDIPitchProjectionTests {
    private func render<S: Sound>(_ sound: S) throws -> PreparedLoop {
        try LoopRenderer().render(SoundCompiler().compile(sound), bpm: 120, beatsPerBar: 4)
    }

    @Test(.timeLimit(.minutes(1)))
    func semanticPitchIncludesPatternTransposeAndRejectsFractionalNotes() throws {
        let base = Synthesizer(.sine).notes("C4")
        let octave = try render(base.transpose(PitchPattern("12")))
        #expect(octave.events[0].midiNote == 60)
        #expect(octave.events[0].midiProjection == .note(72))
        let fraction = try render(base.transpose(PitchPattern("0.5")))
        #expect(fraction.events[0].midiProjection == .unsupported(.fractionalPitch))
        let noise = try render(Synthesizer(.coloredNoise(Noise(color: .white, seed: 1))))
        #expect(noise.events[0].midiProjection == .none)
        #expect(try render(Sample("kick")).events[0].midiProjection == .none)
    }

    @Test(.timeLimit(.minutes(1)))
    func constantAndVaryingPitchHaveDifferentExportCapabilities() throws {
        let steps = try StepAutomation(values: [0, 1], cycle: .whole)
        let constant = try PitchAutomation(.steps(steps), from: Semitones(value: 12), to: Semitones(value: 12))
        let varying = try PitchAutomation(.steps(steps), from: Semitones(value: 0), to: Semitones(value: 12))
        let base = Synthesizer(.sine).notes("C4")
        #expect(try render(base.transpose(constant)).events[0].midiProjection == .note(72))
        #expect(try render(base.transpose(varying)).events[0].midiProjection == .unsupported(.timeVaryingPitch))
        let glide = try Portamento(duration: .seconds(.milliseconds(100)))
        let moving = try render(Synthesizer(.sine).notes("C4 G4").portamento(glide))
        #expect(moving.events.map(\.midiProjection) == [.note(60), .unsupported(.timeVaryingPitch)])
        let neutral = try render(base.pitchEnvelope(Envelope(attack: .zero, decay: .zero,
            sustainLevel: 1, release: .zero), depth: Semitones(value: 12)))
        #expect(neutral.events[0].midiProjection == .note(72))
    }

    private struct FixtureLoader: SampleLoading {
        func load(_ request: SampleLoadRequest) throws -> LoadedSample {
            try LoadedSample(samples: [Float](repeating: 0.1, count: 4096),
                channelCount: 1, sampleRate: PreparedLoop.requiredSampleRate)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func instrumentSettingsPreserveSemanticNote() throws {
        let tuning = try Tuning(referencePitch: .middleC, frequencyHz: 523.2511306011972)
        let instrument = try Synthesizer(.frequencyModulation(FrequencyModulation(ratio: 2, index: 1)))
            .notes("C4").tuning(tuning).unison(Unison(voices: 2, detuneCents: 10))
        #expect(try render(instrument).events[0].midiProjection == .note(60))
        let sample = try Sample(file: URL(fileURLWithPath: "/projection-fixture.wav"))
            .notes("C4").tuning(tuning).samplePlaybackRate(2)
        let rendered = try LoopRenderer(sampleLoader: FixtureLoader()).render(
            SoundCompiler().compile(sample), bpm: 120, beatsPerBar: 4)
        #expect(rendered.events[0].midiProjection == .note(60))
    }

    @Test(.timeLimit(.minutes(1)))
    func projectionRoundTripAndLegacyMetadataAreExplicit() throws {
        let original = try render(Synthesizer(.sine).notes("A4"))
        let encoded = try JSONEncoder().encode(original.events[0])
        #expect(try JSONDecoder().decode(LoopEvent.self, from: encoded) == original.events[0])
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "midiProjection")
        let legacy = try JSONDecoder().decode(LoopEvent.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.midiProjection == .unsupported(.legacyMetadataMissing))
        object.removeValue(forKey: "midiNote")
        let unpitched = try JSONDecoder().decode(LoopEvent.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(unpitched.midiProjection == .none)
    }
}
