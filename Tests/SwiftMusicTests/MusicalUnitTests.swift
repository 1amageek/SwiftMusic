import SwiftMusic
import Testing

struct MusicalUnitTests {
    @Test(.timeLimit(.minutes(3)))
    func standardDurationsAndExplicitBarsPreserveExistingValues() throws {
        let typed = try Envelope(attack: .milliseconds(5), decay: .milliseconds(80),
                                 sustainLevel: 0.5, release: .milliseconds(120))
        let legacy = try Envelope(attackSeconds: 0.005, decaySeconds: 0.08,
                                  sustainLevel: 0.5, releaseSeconds: 0.12)
        #expect(typed == legacy)
        #expect(try MusicalTime.bars(2, beatsPerBar: 3) == .beats(6))
        #expect(try MusicalTime.bars(0, beatsPerBar: 4) == .zero)
        #expect(throws: MusicalTimeError.invalidBeatsPerBar(0)) {
            try MusicalTime.bars(2, beatsPerBar: 0)
        }
        #expect(throws: MusicalTimeError.overflow) {
            try MusicalTime.bars(UInt64.max, beatsPerBar: 2)
        }
        #expect(throws: SoundParameterError.invalidValue("envelope duration")) {
            try Envelope(attack: .nanoseconds(-1), decay: .zero, sustainLevel: 1, release: .zero)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func typedDescriptorsPreserveValuesAndCompilerValidation() throws {
        let frequency = try Frequency(hertz: 440)
        let level = try Decibels(value: -6)
        #expect(try Semitones(value: -0.5).value == -0.5)
        #expect(try Tuning(referencePitch: .middleC, frequency: frequency)
                == Tuning(referencePitch: .middleC, frequencyHz: 440))
        #expect(AudioEffect.equalizer(frequency: frequency, gain: level, q: 0.7)
                == .equalizer(frequencyHz: 440, gainDecibels: -6, q: 0.7))
        #expect(AudioEffect.compressor(threshold: level, ratio: 4)
                == .compressor(thresholdDecibels: -6, ratio: 4))
        #expect(throws: SoundCompilationError.invalidParameter("EQ Q must be finite and positive")) {
            try SoundCompiler().compile(Sample("kick").effect(
                .equalizer(frequency: frequency, gain: level, q: 0)))
        }
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(throws: (any Error).self) { try Frequency(hertz: value) }
            #expect(throws: (any Error).self) { try Decibels(value: value) }
            #expect(throws: (any Error).self) { try Semitones(value: value) }
        }
        #expect(throws: (any Error).self) { try Frequency(hertz: 0) }
        #expect(throws: (any Error).self) { try Frequency(hertz: -1) }
    }
}
