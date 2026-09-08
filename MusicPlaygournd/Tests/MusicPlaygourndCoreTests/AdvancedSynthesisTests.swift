import Accelerate
import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct AdvancedSynthesisTests {
    private func preparation(_ waveform: Waveform, unison: Unison? = nil) throws -> OscillatorPreparation {
        let sound: CompiledSound
        if let unison { sound = try SoundCompiler().compile(Synthesizer(waveform).unison(unison)) }
        else { sound = try SoundCompiler().compile(Synthesizer(waveform)) }
        return try OscillatorPreparation(source: #require(sound.sources.first), waveform: waveform)
    }

    private func signal(_ waveform: Waveform, frequency: Double = 440, count: Int = 16_384,
                        unison: Unison? = nil) throws -> [Float] {
        let prepared = try preparation(waveform, unison: unison)
        var voice = PreparedOscillatorVoice(prepared)
        var samples = [Float](repeating: 0, count: count)
        for frame in samples.indices {
            samples[frame] = Float(try voice.next(prepared, frequency: frequency,
                sourceID: 0, eventIndex: 0, offset: frame))
        }
        return samples
    }

    private func spectrum(_ samples: [Float]) throws -> [Double] {
        let size = samples.count
        let setup = try #require(vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD))
        defer { vDSP_DFT_DestroySetup(setup) }
        let zeros = [Float](repeating: 0, count: size)
        var real = zeros
        var imaginary = zeros
        vDSP_DFT_Execute(setup, samples, zeros, &real, &imaginary)
        return (0..<(size / 2)).map { Double(real[$0] * real[$0] + imaginary[$0] * imaginary[$0]) }
    }

    @Test(.timeLimit(.minutes(1)))
    func bandLimitedSawReducesFoldedHarmonicsAndPulseControlsDuty() throws {
        let size = 16_384
        let bin = 1301
        let frequency = Double(bin) * 44_100 / Double(size)
        let naive = try spectrum(signal(.saw, frequency: frequency))
        let bandLimited = try spectrum(signal(.bandLimitedSaw, frequency: frequency))
        let allowed = Set((1...(size / 2 / bin)).map { $0 * bin })
        var naiveAlias = 0.0
        var correctedAlias = 0.0
        for index in 1..<naive.count where !allowed.contains(index) {
            naiveAlias += naive[index]
            correctedAlias += bandLimited[index]
        }
        #expect(correctedAlias < naiveAlias * 0.2)
        let pulse = try signal(.pulse(PulseWave(width: 0.25)), frequency: 100)
        let mean = pulse.reduce(0.0) { $0 + Double($1) } / Double(pulse.count)
        #expect(abs(mean + 0.5) < 0.02)
    }

    @Test(.timeLimit(.minutes(1)))
    func fmSidebandsAndUnisonFrequenciesAreAudibleAndBounded() throws {
        let size = 16_384
        let bin = 100
        let frequency = Double(bin) * 44_100 / Double(size)
        let fm = try spectrum(signal(.frequencyModulation(FrequencyModulation(ratio: 2, index: 1)), frequency: frequency))
        #expect(fm[bin] > 100)
        #expect(fm[bin * 3] > 100)
        #expect(fm[bin * 5] > 100)
        let unison = try Unison(voices: 3, detuneCents: 100)
        let output = try signal(.sine, frequency: 1000, unison: unison)
        let power = try spectrum(output)
        for cents in [-100.0, 0, 100] {
            let center = Int((1000 * pow(2, cents / 1200) * Double(size) / 44_100).rounded())
            #expect(power[(center - 1)...(center + 1)].max()! > 100_000)
        }
        #expect(throws: LoopRenderingError.self) {
            try signal(.frequencyModulation(FrequencyModulation(ratio: 4, index: 8)), frequency: 1000, count: 1)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func wavetableMipsPreserveFundamentalAndRemoveUnsafeHarmonics() throws {
        let size = 256
        let sine = try Wavetable(samples: (0..<size).map { Float(sin(2 * .pi * Double($0) / Double(size))) })
        let prepared = try WavetablePreparation(sine)
        #expect(prepared.sampleCount == 2048)
        for level in prepared.levels where level.harmonics > 0 {
            #expect(abs(level.value(phase: 0.25) - 1) < 1e-6)
            #expect(abs(level.value(phase: 0.75) + 1) < 1e-6)
        }
        let output = try signal(.wavetable(sine))
        let power = try spectrum(output)
        let peak = try #require(power.indices.dropFirst().max { power[$0] < power[$1] })
        #expect(abs(Double(peak) * 44_100 / Double(output.count) - 440) < 3)
        let saw = try Wavetable(samples: (0..<size).map { Float(2 * Double($0) / Double(size) - 1) })
        let mip = try WavetablePreparation(saw)
        let index = mip.level(frequency: 10_000)
        #expect(mip.levels[index].harmonics <= 2)
        let smallest = try WavetablePreparation(Wavetable(samples: [-1, 1]))
        #expect(smallest.levels.count == 1)
        #expect(smallest.levels[0].value(phase: 0) == -1)
        #expect(smallest.levels[0].value(phase: 0.5) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func noiseSeedsAndSpectralColorsAreDeterministic() throws {
        let white = try signal(.coloredNoise(Noise(color: .white, seed: 7)), count: 32_768)
        let repeatWhite = try signal(.coloredNoise(Noise(color: .white, seed: 7)), count: 32_768)
        let same = white == repeatWhite
        #expect(same)
        let changed = try signal(.coloredNoise(Noise(color: .white, seed: 8)), count: 32_768)
        let differs = white != changed
        #expect(differs)
        let pink = try spectrum(signal(.coloredNoise(Noise(color: .pink, seed: 7)), count: 32_768))
        let brown = try spectrum(signal(.coloredNoise(Noise(color: .brown, seed: 7)), count: 32_768))
        let plain = try spectrum(white)
        func band(_ power: [Double], _ low: Double, _ high: Double) -> Double {
            let first = Int(low * 32_768 / 44_100)
            let end = Int(high * 32_768 / 44_100)
            return power[first..<end].reduce(0, +) / Double(end - first)
        }
        let low = 300.0...600.0
        let high = 2400.0...4800.0
        func ratio(_ power: [Double]) -> Double {
            band(power, high.lowerBound, high.upperBound) / band(power, low.lowerBound, low.upperBound)
        }
        #expect(ratio(pink) < ratio(plain) * 0.3)
        #expect(ratio(brown) < ratio(pink) * 0.3)
    }

    @Test(.timeLimit(.minutes(1)))
    func legacyAndOneLaneIdentityComposeWithSeamlessSynthesis() throws {
        let compiler = SoundCompiler()
        let renderer = LoopRenderer()
        let waveforms: [Waveform] = [.sine, .square, .saw, .triangle, .bandLimitedSaw,
            .pulse(try PulseWave(width: 0.3)), .frequencyModulation(try FrequencyModulation(ratio: 2, index: 1))]
        for waveform in waveforms {
            let base = Synthesizer(waveform).notes("A4")
            let a = try renderer.render(compiler.compile(base), bpm: 120, beatsPerBar: 4)
            let b = try renderer.render(compiler.compile(base.unison(Unison(voices: 1, detuneCents: 1000))),
                bpm: 120, beatsPerBar: 4)
            let identical = a.samples == b.samples
            #expect(identical)
        }
        for waveform: Waveform in [.bandLimitedSaw, .coloredNoise(Noise(color: .brown, seed: 7)),
                                  .coloredNoise(Noise(color: .pink, seed: 7))] {
            let wrapped = try compiler.compile(Synthesizer(waveform).rhythm("~ ~ ~ x").gate(2),
                liveLoop: LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole))
            let a = try renderer.render(wrapped, bpm: 120, beatsPerBar: 4)
            let b = try renderer.render(wrapped, bpm: 120, beatsPerBar: 4)
            let stable = a.samples == b.samples
            #expect(stable)
            #expect(a.samples.prefix(40_000).contains { abs($0) > 0.00001 })
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func wavetableAliasReductionCrossfadeAndPreparationBounds() throws {
        let table = try Wavetable(samples: (0..<256).map { Float(2 * Double($0) / 256 - 1) })
        let frequency = 1301.0 * 44_100 / 16_384
        let naive = try spectrum(signal(.saw, frequency: frequency))
        let filtered = try spectrum(signal(.wavetable(table), frequency: frequency))
        let harmonics = Set((1...6).map { $0 * 1301 })
        var before = 0.0
        var after = 0.0
        for bin in 1..<naive.count where !harmonics.contains(bin) {
            before += naive[bin]
            after += filtered[bin]
        }
        #expect(after < before * 0.1)
        let prepared = try preparation(.wavetable(table))
        var voice = PreparedOscillatorVoice(prepared)
        for frame in 0..<100 {
            _ = try voice.next(prepared, frequency: 100, sourceID: 0, eventIndex: 0, offset: frame)
        }
        _ = try voice.next(prepared, frequency: 10_000, sourceID: 0, eventIndex: 0, offset: 100)
        #expect(voice.tableFade == 31)
        for frame in 101..<132 {
            _ = try voice.next(prepared, frequency: 10_000, sourceID: 0, eventIndex: 0, offset: frame)
        }
        #expect(voice.tableFade == 0)
        let oversized = try SoundCompiler().compile(Synthesizer(.sine).rhythm("x*512")
            .unison(Unison(voices: 16, detuneCents: 10)))
        #expect(throws: LoopRenderingError.self) { try OscillatorPreparation.prepare(oversized) }
        let large = try Wavetable(samples: [Float](repeating: 0, count: 4096))
        let tables = try SoundCompiler().compile(Track("Tables") {
            for _ in 0..<6 { Synthesizer(.wavetable(large)) }
        })
        #expect(throws: LoopRenderingError.self) { try OscillatorPreparation.prepare(tables) }
    }

    @Test(.timeLimit(.minutes(1)))
    func liveControlsRespectUnisonPitchRangeAndNoiseCapability() throws {
        let compiler = SoundCompiler()
        let noise = try LoopRenderSession(sound: compiler.compile(Synthesizer(.coloredNoise(Noise(color: .white, seed: 1)))),
            bpm: 120, beatsPerBar: 4)
        #expect(!noise.catalog.descriptors.contains { $0.address.parameter == .pitchOffsetSemitones })
        let unison = try LoopRenderSession(sound: compiler.compile(Synthesizer(.sine).notes("C4")
            .unison(Unison(voices: 2, detuneCents: 100))), bpm: 120, beatsPerBar: 4)
        let address = try #require(unison.catalog.descriptors.first { $0.address.parameter == .pitchOffsetSemitones }?.address)
        #expect(throws: LoopRenderingError.self) {
            try unison.render(overrides: [.init(address: address, value: .number(67))])
        }
        let valid = try unison.render(overrides: [.init(address: address, value: .number(66))])
        #expect(valid.samples.contains { abs($0) > 0.01 })
    }

    @Test(.timeLimit(.minutes(1)))
    func unisonGlideAppliesAutomationBeforeRangeValidation() throws {
        let automation = try PitchAutomation(.steps(StepAutomation(values: [0], cycle: .whole)),
            from: Semitones(value: 12), to: Semitones(value: 12))
        let compiled = try SoundCompiler().compile(Synthesizer(.sine).notes("C-1 C4")
            .transpose(automation).portamento(Portamento(duration: .seconds(.milliseconds(100))))
            .unison(Unison(voices: 2, detuneCents: 100)))
        let rendered = try LoopRenderer().render(compiled, bpm: 120, beatsPerBar: 4)
        #expect(rendered.events.count == 2)
        #expect(rendered.samples.prefix(40_000).contains { abs($0) > 0.01 })
        #expect(rendered.samples.suffix(40_000).contains { abs($0) > 0.01 })
    }
}
