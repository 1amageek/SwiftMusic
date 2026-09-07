import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
    struct SourceDSPNativeTests {
        @MainActor
        @Test(.timeLimit(.minutes(3)))
        func configuredSourceReachesHardwareTapAndPreservesRevision() async throws {
            let envelope = try Envelope(attack: .milliseconds(10), decay: .milliseconds(20),
                                        sustainLevel: 0.7, release: .milliseconds(50))
            let sound = Synthesizer(.sine).notes("A4 A4 A4 A4")
                .transpose(PitchPattern("0.5 -0.5"))
                .lowPass("800 1600").envelope(envelope).gain(0.1)
            let loop = try LoopRenderer().render(SoundCompiler().compile(sound), bpm: 120, beatsPerBar: 4)
            let engine = try AudioLoopEngine()
            defer { engine.stop() }
            engine.beginUpdate(revision: 31)
            try engine.submit(loop: loop, revision: 31)
            try engine.play()
            try await Task.sleep(for: .milliseconds(350))
            let output = engine.outputMeter()
            #expect(output.sampleRate > 0)
            #expect(output.interleavedSamples.contains { abs($0) > 0.0001 })
            #expect(output.interleavedSamples.allSatisfy { $0.isFinite })
            engine.beginUpdate(revision: 32)
            #expect(throws: (any Error).self) { try engine.submit(loop: loop, revision: 31) }
            #expect(engine.snapshot().revision == 31)
            #expect(engine.snapshot().isPlaying)
        }
    }
}
