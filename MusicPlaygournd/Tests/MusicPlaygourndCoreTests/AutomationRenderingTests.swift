import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct AutomationRenderingTests {
    @Test(.timeLimit(.minutes(3)))
    func rationalAutomationDivisibilityDoesNotDependOnDoubleRounding() throws {
        let period = try MusicalTime(numerator: 5, denominator: 29)
        let policy = try LiveLoopPolicy(beatsPerBar: 5, maximumBeats: .beats(32))
        let signal = AutomationSignal.lfo(try LFO(waveform: .sine, rate: .synchronized(period: period)))
        let source = Synthesizer(.sine).notes("C4").oneShot()
            .gain(try GainAutomation(signal, from: 0.2, to: 0.8))
        let compiled = try SoundCompiler().compile(source, liveLoop: policy)
        #expect(compiled.extent == .beats(5))
        let loop = try LoopRenderer().render(compiled, bpm: 120, beatsPerBar: 5)
        #expect(loop.beatCount == 5)
        #expect(loop.samples.contains { abs($0) > 0.01 })
    }

    @Test(.timeLimit(.minutes(3)))
    func liveReplayPreservesFinitePitchOrderAndOneShotSemantics() throws {
        let compiler = SoundCompiler()
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .beats(32))
        let signal = AutomationSignal.steps(try StepAutomation(values: [0, 1], cycle: .whole))
        let down = try PitchAutomation(signal, from: Semitones(value: -12), to: Semitones(value: 0))
        let up = try PitchAutomation(signal, from: Semitones(value: 0), to: Semitones(value: 12))
        let source = Synthesizer(.sine).notes("C9").transpose(down).transpose(-12).transpose(up)
        let finite = try compiler.compile(source)
        let live = try compiler.compile(source, liveLoop: policy)
        #expect(live.events.map(\.pitch) == finite.events.map(\.pitch))
        let oneShot = try compiler.compile(Synthesizer(.sine).notes("C4").oneShot()
            .gain(GainPattern("1").slow(64)), liveLoop: policy)
        #expect(oneShot.extent == .whole)
        #expect(oneShot.events.count == 1)
    }

    @Test(.timeLimit(.minutes(3)))
    func gainOrderContinuesThroughEffectTails() throws {
        let automation = try GainAutomation(.steps(StepAutomation(values: [0, 1], cycle: .beats(8))), from: 0, to: 1)
        let source = Synthesizer(.sine).notes("C4 ~ ~ ~")
        let effect = AudioEffect.delay(time: .whole, feedback: 0, wet: 1)
        let compiler = SoundCompiler()
        let renderer = LoopRenderer()
        let outside = try renderer.render(compiler.compile(source.effect(effect).gain(automation)), bpm: 120, beatsPerBar: 4)
        let inside = try renderer.render(compiler.compile(source.gain(automation).effect(effect)), bpm: 120, beatsPerBar: 4)
        #expect(outside.beatCount == 8)
        #expect(outside.samples.prefix(176_400).allSatisfy { abs($0) < 0.00001 })
        #expect(outside.samples.dropFirst(176_400).contains { abs($0) > 0.01 })
        #expect(inside.samples.allSatisfy { abs($0) < 0.00001 })
        #expect(outside.events == inside.events)
    }

    @Test(.timeLimit(.minutes(3)))
    func pitchAutomationMovesOscillatorAndSampleTraversalOnTheTransportClock() throws {
        let steps = try StepAutomation(values: [0, 1], cycle: .whole)
        let pitch = try PitchAutomation(.steps(steps), from: Semitones(value: 0), to: Semitones(value: 12))
        let compiler = SoundCompiler()
        let oscillator = try LoopRenderer().render(compiler.compile(Synthesizer(.sine).notes("A4").transpose(pitch)), bpm: 120, beatsPerBar: 4)
        let sample = try Sample(file: URL(fileURLWithPath: "/automation-fixture.wav"), rootPitch: Pitch(midiNote: 69))
        let file = try LoopRenderer(sampleLoader: SineLoader()).render(
            compiler.compile(sample.notes("A4").transpose(pitch)), bpm: 120, beatsPerBar: 4)
        for loop in [oscillator, file] {
            #expect(abs(frequency(loop, frames: 4_410..<22_050) - 440) < 5)
            #expect(abs(frequency(loop, frames: 48_510..<66_150) - 880) < 5)
        }
        let offset = try LoopRenderer().render(compiler.compile(Synthesizer(.sine)
            .notes("~ A4 ~ A4").transpose(pitch)), bpm: 120, beatsPerBar: 4)
        #expect(abs(frequency(offset, frames: 26_460..<39_690) - 440) < 5)
        #expect(abs(frequency(offset, frames: 70_560..<83_790) - 880) < 5)
    }

    @Test(.timeLimit(.minutes(3)))
    func automatedCutoffChangesMeasuredPCMAndRejectsEnvelopeNyquistOverflow() throws {
        let signal = AutomationSignal.steps(try StepAutomation(values: [0, 1], cycle: .whole))
        let cutoff = try CutoffAutomation(signal, from: Frequency(hertz: 100), to: Frequency(hertz: 8_000))
        let source = Synthesizer(.saw).notes("A4").lowPass(cutoff)
        let renderer = LoopRenderer()
        let loop = try renderer.render(SoundCompiler().compile(source), bpm: 120, beatsPerBar: 4)
        #expect(energy(loop, frames: 48_510..<66_150) > energy(loop, frames: 4_410..<22_050) * 4)
        let envelope = try Envelope(attack: .milliseconds(1), decay: .milliseconds(1),
            sustainLevel: 1, release: .milliseconds(1))
        let excessive = try SoundCompiler().compile(source.filterEnvelope(envelope, depth: Semitones(value: 24)))
        #expect(throws: LoopRenderingError.self) {
            try renderer.render(excessive, bpm: 120, beatsPerBar: 4)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func roundedSeamUsesAnExactBeatCycleAndPhysicalHertzClock() throws {
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .beats(32))
        let signal = AutomationSignal.lfo(try LFO(waveform: .sawUp, rate: .synchronized(period: .whole)))
        let gain = try GainAutomation(signal, from: 0, to: 1)
        let source = Synthesizer(.sine).notes("A4")
        let compiler = SoundCompiler()
        let renderer = LoopRenderer()
        let base = try renderer.render(compiler.compile(source, liveLoop: policy), bpm: 137, beatsPerBar: 4)
        let loop = try renderer.render(compiler.compile(source.gain(gain), liveLoop: policy), bpm: 137, beatsPerBar: 4)
        let frames = loop.samples.count / 2
        for frame in stride(from: 1_000, to: frames - 1_000, by: 1_973) {
            let expected = Double(base.samples[frame * 2]) * Double(frame) / Double(frames)
            #expect(abs(Double(loop.samples[frame * 2]) - expected) < 0.000001)
        }
        let secondsPerBeat = Double(frames) / 44_100 / 4
        #expect(try AutomationEvaluator.value(signal, frame: frames, secondsPerBeat: secondsPerBeat) < 0.0000001)
        let nominalHz = try Frequency(hertz: 137 / 240)
        // This frequency completes exactly 1,073 cycles in the rounded window.
        let physicalHz = try Frequency(hertz: 612.5)
        let rejected = try compiler.compile(source.gain(GainAutomation(.lfo(LFO(waveform: .sine,
            rate: .hertz(nominalHz))), from: 0, to: 1)), liveLoop: policy)
        #expect(throws: LoopRenderingError.self) { try renderer.render(rejected, bpm: 137, beatsPerBar: 4) }
        let accepted = try compiler.compile(source.gain(GainAutomation(.lfo(LFO(waveform: .sine,
            rate: .hertz(physicalHz))), from: 0, to: 1)), liveLoop: policy)
        #expect(try renderer.render(accepted, bpm: 137, beatsPerBar: 4).samples.contains { abs($0) > 0.01 })
    }

    private func frequency(_ loop: PreparedLoop, frames: Range<Int>) -> Double {
        var crossings = 0
        for frame in frames.dropFirst() {
            if loop.samples[(frame - 1) * 2] <= 0, loop.samples[frame * 2] > 0 { crossings += 1 }
        }
        return Double(crossings) * 44_100 / Double(frames.count)
    }

    private func energy(_ loop: PreparedLoop, frames: Range<Int>) -> Double {
        frames.reduce(0) { $0 + pow(Double(loop.samples[$1 * 2]), 2) }
    }

    private struct SineLoader: SampleLoading {
        func load(_ request: SampleLoadRequest) throws -> LoadedSample {
            let samples = (0..<(4 * 44_100)).map { Float(sin(2 * .pi * 440 * Double($0) / 44_100)) }
            return try LoadedSample(samples: samples, channelCount: 1, sampleRate: 44_100)
        }
    }
}
