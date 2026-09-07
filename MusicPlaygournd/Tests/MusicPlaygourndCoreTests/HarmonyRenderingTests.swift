import AVFoundation
import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct HarmonyRenderingTests {
    @Test(.timeLimit(.minutes(3)))
    func oscillatorAndDecodedSampleFollowSameGlideAndExhaustion() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "Glide-\(UUID().uuidString).caf")
        defer {
            do { try FileManager.default.removeItem(at: url) }
            catch { Issue.record(error) }
        }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200))
        buffer.frameLength = buffer.frameCapacity
        let data = try #require(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            data[0][frame] = Float(sin(2 * Double.pi * 440 * Double(frame) / 44_100))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
        let glide = try Portamento(duration: .seconds(.milliseconds(200)))
        let compiler = SoundCompiler()
        let synth = try compiler.compile(Synthesizer(.sine).notes("A4 A5").portamento(glide))
        let sample = try compiler.compile(Sample(file: url, rootPitch: Pitch(midiNote: 69))
            .notes("A4 A5").portamento(glide))
        let oscillator = try LoopRenderer().render(synth, bpm: 120, beatsPerBar: 4)
        let decoded = try LoopRenderer().render(sample, bpm: 120, beatsPerBar: 4)
        #expect(oscillator.samples.count == decoded.samples.count)
        var maximumError: Float = 0
        for index in oscillator.samples.indices {
            maximumError = max(maximumError, abs(oscillator.samples[index] - decoded.samples[index]))
        }
        #expect(maximumError < 0.0003)
        let event = synth.events[1]
        let source = synth.sources[0]
        #expect(try PitchGlide.midi(event: event, source: source, time: 0, secondsPerBeat: 0.5) == 69)
        #expect(try PitchGlide.midi(event: event, source: source, time: 0.1, secondsPerBeat: 0.5) == 75)
        #expect(try PitchGlide.midi(event: event, source: source, time: 0.3, secondsPerBeat: 0.5) == 81)
        // Measure the real PCM's destination frequency after the glide, away from the edge ramp.
        let start = Int(1.3 * 44_100), end = Int(1.4 * 44_100)
        let crossings = (start..<end).filter {
            oscillator.samples[$0 * 2] <= 0 && oscillator.samples[($0 + 1) * 2] > 0
        }.count
        #expect(abs(crossings - 88) <= 1)
        let short = try LoadedSample(samples: Array(repeating: Float(0.1), count: 10_000),
                                     channelCount: 1, sampleRate: 44_100)
        let voice = PreparedSampleVoice(sample: short, rootPitch: try Pitch(midiNote: 69))
        let frames = try voice.frames(event: event, source: source, secondsPerBeat: 0.5, limit: 44_100)
        var position = 0.0
        var stayedInBounds = true
        for frame in 0..<frames {
            stayedInBounds = stayedInBounds && position < Double(short.frameCount)
            position += try voice.increment(event: event, source: source,
                                            time: Double(frame) / 44_100, secondsPerBeat: 0.5)
        }
        #expect(stayedInBounds && position >= Double(short.frameCount))
    }

    @Test(.timeLimit(.minutes(3)))
    func beatAndSecondsGlidesComposeWithAutomationAcrossLiveWrap() throws {
        let compiler = SoundCompiler()
        let beat = try Portamento(duration: .beats(.quarter))
        let seconds = try Portamento(duration: .seconds(.milliseconds(500)))
        let base = Synthesizer(.sine).notes("A4 A5").gate(0.9)
        let a = try compiler.compile(base.portamento(beat))
        let b = try compiler.compile(base.portamento(seconds))
        #expect(try PitchGlide.midi(event: a.events[1], source: a.sources[0], time: 0.25, secondsPerBeat: 1) == 72)
        #expect(try PitchGlide.midi(event: b.events[1], source: b.sources[0], time: 0.25, secondsPerBeat: 1) == 75)
        let live = try compiler.compile(base.portamento(beat),
            liveLoop: LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole))
        #expect(live.events[0].portamentoStartMIDINote == 81)
        let loop = try LoopRenderer().render(live, bpm: 120, beatsPerBar: 4)
        #expect(loop.samples.contains { abs($0) > 0.01 })
        #expect(loop.samples.allSatisfy { $0.isFinite })
        #expect(loop.events.map(\.patternStepIndex) == [0, 1])
        let longGlide = try Portamento(duration: .beats(.half))
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)
        let original = try LoopRenderer().render(compiler.compile(base.portamento(longGlide), liveLoop: policy),
                                                bpm: 120, beatsPerBar: 4)
        let shifted = try LoopRenderer().render(compiler.compile(base.portamento(longGlide).offset(.quarter), liveLoop: policy),
                                               bpm: 120, beatsPerBar: 4)
        var seamDifference: Float = 0
        let shift = 22_050 * 2
        for index in original.samples.indices {
            seamDifference = max(seamDifference, abs(original.samples[index]
                - shifted.samples[(index + shift) % shifted.samples.count]))
        }
        #expect(seamDifference < 0.000001)
        let octave = try PitchAutomation(.steps(StepAutomation(values: [1], cycle: .whole)),
                                        from: Semitones(value: 12), to: Semitones(value: 12))
        let automated = try LoopRenderer().render(compiler.compile(base.portamento(beat).transpose(octave)),
                                                 bpm: 120, beatsPerBar: 4)
        let transposed = try LoopRenderer().render(compiler.compile(base.transpose(12).portamento(beat)),
                                                  bpm: 120, beatsPerBar: 4)
        var difference: Float = 0
        for index in automated.samples.indices {
            difference = max(difference, abs(automated.samples[index] - transposed.samples[index]))
        }
        #expect(difference < 0.000001)
    }

    @Test(.timeLimit(.minutes(3)))
    func unsupportedAndOutOfRangeGlidesFail() throws {
        let glide = try Portamento(duration: .seconds(.milliseconds(100)))
        #expect(throws: (any Error).self) {
            try SoundCompiler().compile(Sample("kick").portamento(glide))
        }
        #expect(throws: (any Error).self) {
            try SoundCompiler().compile(Synthesizer(.noise).portamento(glide))
        }
        #expect(throws: HarmonyError.invalidPortamento) { try Portamento(duration: .seconds(.zero)) }
        let high = try SoundCompiler().compile(Synthesizer(.sine).notes("C9 C4").portamento(glide)
            .tuning(Tuning(referencePitch: Pitch(midiNote: 69), frequencyHz: 2_000)))
        #expect(throws: (any Error).self) {
            try LoopRenderer().render(high, bpm: 120, beatsPerBar: 4)
        }
    }
}
