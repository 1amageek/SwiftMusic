import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct SourceDSPRenderingTests {
    @Test(.timeLimit(.minutes(3)))
    func legacyPCMRemainsIdentical() throws {
        let compiler = SoundCompiler()
        let renderer = LoopRenderer()
        let expected: [UInt64] = [660_509_564_236_254_901, 8_973_563_278_011_062_033]
        for (index, sound) in [Synthesizer(.sine).notes("C4 D4"), Sample("kick").rhythm("x ~ x ~")].enumerated() {
            let loop = try renderer.render(compiler.compile(sound), bpm: 120, beatsPerBar: 4)
            let hash = loop.samples.reduce(UInt64(14_695_981_039_346_656_037)) {
                ($0 ^ UInt64($1.bitPattern)) &* 1_099_511_628_211
            }
            #expect(hash == expected[index])
        }
    }

    private func render<S: Sound>(_ sound: S) throws -> PreparedLoop {
        try LoopRenderer().render(SoundCompiler().compile(sound), bpm: 120, beatsPerBar: 4)
    }

    private func rms(_ loop: PreparedLoop, from: Double = 0.2, to: Double = 0.8) -> Double {
        let first = Int(from * loop.sampleRate), end = Int(to * loop.sampleRate)
        var energy = 0.0
        for frame in first..<end { energy += pow(Double(loop.samples[frame * 2]), 2) }
        return sqrt(energy / Double(end - first))
    }

    private func frequency(_ loop: PreparedLoop, from: Double, to: Double) -> Double {
        let first = Int(from * loop.sampleRate), end = Int(to * loop.sampleRate)
        var crossings = 0
        for frame in (first + 1)..<end {
            if loop.samples[(frame - 1) * 2] <= 0, loop.samples[frame * 2] > 0 { crossings += 1 }
        }
        return Double(crossings) / (to - from)
    }

    @Test(.timeLimit(.minutes(3)))
    func envelopeSegmentsAndEarlyReleaseUseTheActualAnchorLevel() throws {
        let envelope = try Envelope(attackSeconds: 1, decaySeconds: 1, sustainLevel: 0.25,
                                    releaseSeconds: 1, attackCurve: .exponential(exponent: 2))
        let contour = VoiceEnvelope(envelope, noteDuration: 4, gate: 0.125)
        #expect(contour.value(at: 0) == 0)
        #expect(contour.value(at: 0.25) == 0.0625)
        #expect(contour.value(at: 0.5) == 0.25)
        #expect(contour.value(at: 1) == 0.125)
        #expect(contour.value(at: 1.5) == 0)
        let full = VoiceEnvelope(envelope, noteDuration: 3, gate: 1)
        #expect(full.value(at: 1) == 1)
        #expect(full.value(at: 1.5) == 0.625)
        #expect(full.value(at: 2) == 0.25)
        let immediate = try Envelope(attackSeconds: 0, decaySeconds: 0, sustainLevel: 0.7,
                                     releaseSeconds: 0, releaseAnchor: .eventEnd)
        let zero = VoiceEnvelope(immediate, noteDuration: 1, gate: 0.1)
        #expect(zero.value(at: 0) == 0.7)
        #expect(zero.value(at: 0.5) == 0.7)
        #expect(zero.value(at: 1) == 0)
    }

    @Test(.timeLimit(.minutes(3)))
    func renderedEnvelopeOverridesSourceAndIncludesCompleteRelease() throws {
        let source = try Envelope(attackSeconds: 0, decaySeconds: 0, sustainLevel: 0,
                                  releaseSeconds: 0)
        let audible = try Envelope(attackSeconds: 0, decaySeconds: 0, sustainLevel: 1,
                                   releaseSeconds: 0.25)
        let sound = Synthesizer(.sine).notes("A4").envelope(source)
            .envelope(try EnvelopePattern(steps: [audible]))
        let loop = try render(sound)
        #expect(loop.beatCount == 8)
        #expect(loop.events[0].durationBeats == 4.5)
        #expect(rms(loop) > 0.1)
        #expect(rms(loop, from: 2.01, to: 2.1) > 0.01)
        #expect(rms(loop, from: 2.3, to: 2.4) == 0)
        let cleared = try render(sound.envelope(source))
        #expect(rms(cleared) == 0)
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)
        #expect(throws: (any Error).self) {
            try LoopRenderer().render(SoundCompiler().compile(sound, liveLoop: policy), bpm: 120, beatsPerBar: 4)
        }
        let crossing = Synthesizer(.sine).notes("A4").gate(0.5)
            .offset(try MusicalTime(numerator: 3, denominator: 1)).envelope(audible)
            .lowPass(try Frequency(hertz: 800))
        let compiled = try SoundCompiler().compile(crossing, liveLoop: policy)
        let circular = try LoopRenderer().render(compiled, bpm: 120, beatsPerBar: 4)
        #expect(circular.events[0].wrapsLoopBoundary)
        #expect(circular.events[0].durationBeats == 2.5)
        #expect(rms(circular, from: 0.01, to: 0.1) > 0.1)
        let finite = try render(crossing)
        let start = Int(1.5 * circular.sampleRate)
        let frames = Int(1.25 * circular.sampleRate)
        var maximumError: Float = 0
        for offset in 0..<frames {
            let folded = (start + offset) % (circular.samples.count / 2)
            maximumError = max(maximumError,
                abs(circular.samples[folded * 2] - finite.samples[(start + offset) * 2]))
        }
        #expect(maximumError == 0)
    }

    @Test(.timeLimit(.minutes(3)))
    func tuningFractionalPitchAndIntegratedPitchSweepReachPCM() throws {
        let sound = Synthesizer(.sine).notes("A4")
        let plain = try render(sound)
        #expect(abs(frequency(plain, from: 0.1, to: 0.9) - 440) < 2)
        let fractional = try render(sound.transpose(PitchPattern("0.5")))
        #expect(abs(frequency(fractional, from: 0.1, to: 0.9) - 440 * pow(2, 0.5 / 12)) < 2)
        let tuned = try render(sound.tuning(try Tuning(referencePitch: Pitch(midiNote: 69), frequencyHz: 220)))
        #expect(abs(frequency(tuned, from: 0.1, to: 0.9) - 220) < 2)
        let envelope = try Envelope(attackSeconds: 0.5, decaySeconds: 0, sustainLevel: 1, releaseSeconds: 0)
        let swept = try render(sound.pitchEnvelope(envelope, depth: Semitones(value: 12)))
        #expect(frequency(swept, from: 0.6, to: 0.9) > frequency(swept, from: 0.05, to: 0.2) * 1.5)
        var largestStep: Float = 0
        for frame in 1..<Int(swept.sampleRate) {
            largestStep = max(largestStep, abs(swept.samples[frame * 2] - swept.samples[(frame - 1) * 2]))
        }
        #expect(largestStep < 0.04)
        #expect(throws: (any Error).self) {
            try render(sound.pitchEnvelope(envelope, depth: Semitones(value: 1000)))
        }
        #expect(throws: LoopRenderingError.unsupportedSourceSetting(sourceID: 0, setting: "sample pitch traversal")) {
            try render(Sample("kick").notes("C4").transpose(PitchPattern("1")))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func sourceFiltersHaveMeasuredResponseSlopeResonanceAndModulation() throws {
        let sound = Synthesizer(.sine).notes("A4")
        let cutoff = try Frequency(hertz: 100)
        let plain = try render(sound)
        let low = try render(sound.lowPass(cutoff))
        let steep = try render(sound.lowPass(cutoff, slope: .twentyFour))
        let high = try render(sound.highPass(cutoff))
        let band = try render(sound.bandPass(Frequency(hertz: 440)))
        #expect(rms(low) < rms(plain) * 0.06)
        #expect(rms(steep) < rms(low) * 0.06)
        #expect(rms(high) > rms(plain) * 0.9)
        #expect(abs(rms(band) / rms(plain) - 1) < 0.01)
        let bandLow = try render(sound.bandPass(cutoff))
        let bandSteep = try render(sound.bandPass(cutoff, slope: .twentyFour))
        let omega = 2 * Double.pi * 440 / plain.sampleRate
        let center = 2 * Double.pi * 100 / plain.sampleRate
        let alpha = sin(center) / (2 * 0.7071067811865476)
        // Magnitude of one RBJ band-pass section evaluated on the unit circle.
        let numerator = 2 * alpha * sin(omega)
        let real = 2 * (cos(omega) - cos(center))
        let imaginary = 2 * alpha * sin(omega)
        let sectionGain = abs(numerator) / sqrt(real * real + imaginary * imaginary)
        #expect(abs(rms(bandLow) / rms(plain) - pow(sectionGain, 2)) < 0.001)
        #expect(abs(rms(bandSteep) / rms(plain) - pow(sectionGain, 4)) < 0.001)
        let resonant = try render(sound.lowPass(Frequency(hertz: 440), resonanceQ: 2))
        #expect(rms(resonant) > rms(plain) * 1.9)
        let envelope = try Envelope(attackSeconds: 0.5, decaySeconds: 0, sustainLevel: 1, releaseSeconds: 0)
        let swept = try render(sound.lowPass(cutoff).filterEnvelope(envelope, depth: Semitones(value: 36)))
        #expect(rms(swept, from: 0.6, to: 0.9) > rms(swept, from: 0.01, to: 0.1) * 5)
        #expect(throws: (any Error).self) { try render(sound.lowPass(Frequency(hertz: 30_000))) }
        #expect(throws: (any Error).self) {
            try render(sound.lowPass(cutoff).filterEnvelope(envelope, depth: Semitones(value: 1000)))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func biquadImpulseMatchesIndependentDirectFormRecurrence() throws {
        let compiled = try SoundCompiler().compile(Synthesizer(.sine).lowPass(Frequency(hertz: 1_000)))
        var filter = VoiceFilter(try #require(compiled.sources[0].filter))
        let omega = 2 * Double.pi * 1_000 / PreparedLoop.requiredSampleRate
        let alpha = sin(omega) / (2 * 0.7071067811865476)
        let denominator = 1 + alpha
        let b0 = (1 - cos(omega)) / (2 * denominator)
        let b1 = 2 * b0, b2 = b0
        let a1 = -2 * cos(omega) / denominator, a2 = (1 - alpha) / denominator
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for frame in 0..<512 {
            let input = frame == 0 ? 1.0 : 0.0
            let expected = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            let actual = try filter.process(input, cutoff: 1_000, eventIndex: 0)
            #expect(abs(actual - expected) < 1e-12)
            x2 = x1; x1 = input; y2 = y1; y1 = expected
        }
        #expect(throws: (any Error).self) {
            try filter.process(.infinity, cutoff: 1_000, eventIndex: 0)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func proceduralSampleEnvelopeAndFilterRenderActualPCM() throws {
        let envelope = try Envelope(attack: .milliseconds(20), decay: .milliseconds(50),
                                    sustainLevel: 0.4, release: .milliseconds(20))
        let plain = try render(Sample("kick"))
        let configured = try render(Sample("kick").envelope(envelope).lowPass(Frequency(hertz: 200)))
        #expect(configured.samples.allSatisfy { $0.isFinite })
        #expect(configured.samples.contains { abs($0) > 0.001 })
        #expect(configured.samples != plain.samples)
        #expect(configured.samples[0] == 0)
        #expect(configured.events[0].durationBeats == 1.04)
    }

    @Test(.timeLimit(.minutes(3)))
    func whiteNoiseRejectsPitchSettingsAndPreservesDeterministicDefaults() throws {
        #expect(throws: LoopRenderingError.unsupportedSourceSetting(
            sourceID: 0, setting: "white noise has no pitched oscillator")) {
            try render(Synthesizer(.noise).transpose(PitchPattern("1")))
        }
        let plain = try render(Synthesizer(.noise))
        let zero = try render(Synthesizer(.noise).transpose(PitchPattern("0")))
        #expect(plain.samples == zero.samples)
        #expect(plain.samples.allSatisfy { $0.isFinite })
        #expect(plain.samples.contains { abs($0) > 0.001 })
    }
}
