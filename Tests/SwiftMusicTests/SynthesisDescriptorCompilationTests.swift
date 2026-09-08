import Testing
@testable import SwiftMusic

struct SynthesisDescriptorCompilationTests {
    @Test(.timeLimit(.minutes(3)))
    func descriptorsValidateAndRetainTheirValues() throws {
        let pulse = try PulseWave(width: 0.25)
        let fm = try FrequencyModulation(ratio: 2, index: 3)
        let noise = Noise(color: .pink, seed: 42)
        let table = try Wavetable(samples: [-1, -0.25, 0.5, 1])

        #expect(pulse.width == 0.25)
        #expect(fm.ratio == 2)
        #expect(fm.index == 3)
        #expect(noise.color == .pink)
        #expect(noise.seed == 42)
        #expect(table.samples == [-1, -0.25, 0.5, 1])
        #expect(Waveform.sawtooth == .saw)
        #expect(Waveform.pulse(pulse) == .pulse(pulse))
        #expect(Waveform.frequencyModulation(fm) == .frequencyModulation(fm))
        #expect(Waveform.coloredNoise(noise) == .coloredNoise(noise))
        #expect(Waveform.wavetable(table) == .wavetable(table))
    }

    @Test(.timeLimit(.minutes(3)))
    func descriptorsRejectInvalidValuesBeforeCompilation() throws {
        #expect(throws: SynthesizerDescriptorError.invalidPulseWidth) {
            try PulseWave(width: 0)
        }
        #expect(throws: SynthesizerDescriptorError.invalidPulseWidth) {
            try PulseWave(width: .infinity)
        }
        #expect(throws: SynthesizerDescriptorError.invalidFrequencyModulationRatio) {
            try FrequencyModulation(ratio: 0, index: 1)
        }
        #expect(throws: SynthesizerDescriptorError.invalidFrequencyModulationIndex) {
            try FrequencyModulation(ratio: 1, index: -.infinity)
        }
        #expect(throws: SynthesizerDescriptorError.invalidWavetableLength) {
            try Wavetable(samples: [0, 1, 0])
        }
        #expect(throws: SynthesizerDescriptorError.invalidWavetableSample(index: 1)) {
            try Wavetable(samples: [0, .nan])
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func compilerRetainsNewWaveformsAndPitchedMetadata() throws {
        let pulse = try PulseWave(width: 0.4)
        let fm = try FrequencyModulation(ratio: 1.5, index: 2)
        let table = try Wavetable(samples: [-1, 0, 1, 0])
        let tuning = try Tuning(referencePitch: .middleC, frequencyHz: 442)
        let compiled = try SoundCompiler().compile(
            Synthesizer(.pulse(pulse)).tuning(tuning)
        )
        #expect(compiled.sources[0].kind == .synthesizer(.pulse(pulse)))
        #expect(compiled.sources[0].tuning == tuning)

        let fmCompiled = try SoundCompiler().compile(Synthesizer(.frequencyModulation(fm)))
        #expect(fmCompiled.sources[0].kind == .synthesizer(.frequencyModulation(fm)))

        let tableCompiled = try SoundCompiler().compile(Synthesizer(.wavetable(table)))
        #expect(tableCompiled.sources[0].kind == .synthesizer(.wavetable(table)))
    }

    @Test(.timeLimit(.minutes(3)))
    func newPitchedWaveformsAcceptUnisonAndPreserveEvents() throws {
        let unison = try Unison(voices: 3, detuneCents: 12)
        let pulse = try PulseWave(width: 0.5)
        let fm = try FrequencyModulation(ratio: 2, index: 1)
        let table = try Wavetable(samples: [-1, 0, 1, 0])
        let waveforms: [Waveform] = [
            .bandLimitedSaw,
            .pulse(pulse),
            .frequencyModulation(fm),
            .wavetable(table)
        ]

        for waveform in waveforms {
            let compiled = try SoundCompiler().compile(
                Synthesizer(waveform).notes("C4").unison(unison)
            )
            #expect(compiled.sources[0].unison == unison)
            #expect(compiled.events.count == 1)
            #expect(compiled.events[0].pitch?.midiNote == 60)
        }

        let boundaryUnison = try Unison(voices: 2, detuneCents: 7_000)
        #expect(throws: SoundCompilationError.pitchOutOfRange) {
            try SoundCompiler().compile(
                Synthesizer(.bandLimitedSaw).notes("C4").unison(boundaryUnison)
            )
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func unisonCombinesPortamentoStartBeforePitchAutomationExtrema() throws {
        let automation = try PitchAutomation(
            .steps(try StepAutomation(values: [1], cycle: .whole)),
            from: try Semitones(value: 12),
            to: try Semitones(value: 12)
        )
        let glide = try Portamento(duration: .beats(.quarter))
        let validUnison = try Unison(voices: 2, detuneCents: 100)
        let invalidUnison = try Unison(voices: 2, detuneCents: 1_300)
        let base = Synthesizer(.sine)
            .rhythm("x x", cycle: .half)
            .notes([try Pitch(midiNote: 0), try Pitch(midiNote: 60)])
            .transpose(automation)
            .portamento(glide)

        let compiled = try SoundCompiler().compile(base.unison(validUnison))
        #expect(compiled.events.count == 2)
        #expect(compiled.events.map { $0.pitch?.midiNote } == [0, 60])
        #expect(compiled.events[1].portamentoStartMIDINote == 0)
        #expect(compiled.sources[0].unison == validUnison)

        #expect(throws: SoundCompilationError.pitchOutOfRange) {
            try SoundCompiler().compile(base.unison(invalidUnison))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func coloredNoiseRejectsPitchSettingsAndUnison() throws {
        let noise = Noise(color: .brown, seed: 7)
        let envelope = try Envelope(
            attackSeconds: 0, decaySeconds: 0, sustainLevel: 1, releaseSeconds: 0
        )
        let modulation = try PitchAutomation(
            .steps(try StepAutomation(values: [0, 1], cycle: .whole)),
            from: try Semitones(value: 0), to: try Semitones(value: 1)
        )
        let portamento = try Portamento(duration: .seconds(.milliseconds(100)))
        let unison = try Unison(voices: 2, detuneCents: 10)

        #expect(throws: SoundCompilationError.self) {
            try SoundCompiler().compile(Synthesizer(.coloredNoise(noise)).tuning(
                try Tuning(referencePitch: .middleC, frequencyHz: 442)
            ))
        }
        #expect(throws: SoundCompilationError.self) {
            try SoundCompiler().compile(Synthesizer(.coloredNoise(noise)).pitchEnvelope(
                envelope, depth: try Semitones(value: 1)
            ))
        }
        #expect(throws: SoundCompilationError.self) {
            try SoundCompiler().compile(Synthesizer(.coloredNoise(noise)).transpose(modulation))
        }
        #expect(throws: SoundCompilationError.self) {
            try SoundCompiler().compile(Synthesizer(.coloredNoise(noise)).portamento(portamento))
        }
        #expect(throws: SoundCompilationError.self) {
            try SoundCompiler().compile(Synthesizer(.coloredNoise(noise)).unison(unison))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func legacyNoiseAndSampleCompatibilityRemainsExplicit() throws {
        let compiled = try SoundCompiler().compile(Synthesizer(.noise))
        #expect(compiled.sources[0].kind == .synthesizer(.noise))
        #expect(compiled.sources[0].unison == nil)

        let unison = try Unison(voices: 2, detuneCents: 5)
        #expect(throws: SoundCompilationError.self) {
            try SoundCompiler().compile(Synthesizer(.noise).unison(unison))
        }
        #expect(throws: SoundCompilationError.self) {
            try SoundCompiler().compile(Sample("kick").unison(unison))
        }
    }
}
