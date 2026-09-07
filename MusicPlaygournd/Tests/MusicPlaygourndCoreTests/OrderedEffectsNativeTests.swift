import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
    struct OrderedEffectsNativeTests {
        @MainActor
        @Test(.timeLimit(.minutes(3)))
        func declaredEffectPCMReachesHardwareAndRejectedTailRetainsPlayback() async throws {
            let source = Synthesizer(.sine).notes("C3 C3 C3 C3")
            let compiled = try SoundCompiler().compile(source
                .effect(.equalizer(frequencyHz: 500, gainDecibels: 3, q: 0.7))
                .effect(.saturation(drive: 0.5))
                .effect(.delay(time: .eighth, feedback: 0, wet: 0.2))
                .effect(.reverb(roomSize: 0.2, wet: 0.2)))
            let renderer = LoopRenderer()
            let loop = try renderer.render(compiled, bpm: 120, beatsPerBar: 4)
            #expect(loop.beatCount > 4)
            #expect(loop.samples.dropFirst(176_400).contains { abs($0) > 0.00001 })
            let engine = try AudioLoopEngine()
            defer { engine.stop() }
            engine.beginUpdate(revision: 42)
            try engine.submit(loop: loop, revision: 42)
            try engine.play()
            try await Task.sleep(for: .milliseconds(350))
            let meter = engine.outputMeter()
            #expect(meter.sampleRate > 0)
            #expect(meter.interleavedSamples.allSatisfy { $0.isFinite })
            #expect(meter.interleavedSamples.contains { abs($0) > 0.0001 })
            engine.beginUpdate(revision: 43)
            let excessive = try SoundCompiler().compile(source.effect(.delay(time: .quarter, feedback: 0.99, wet: 1)))
            #expect(throws: LoopRenderingError.self) {
                try renderer.render(excessive, bpm: 120, beatsPerBar: 4)
            }
            #expect(engine.snapshot().revision == 42)
            #expect(engine.snapshot().isPlaying)
        }
    }
}
