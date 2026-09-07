import AVFoundation
import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
    struct SourceDSPNativeTests {
        @MainActor
        @Test(.timeLimit(.minutes(3)))
        func decodedFileReachesNativeOutputAndFailedLoadPreservesPlayback() async throws {
            let url = FileManager.default.temporaryDirectory.appending(path: "NativeSample-\(UUID().uuidString).caf")
            defer {
                do { try FileManager.default.removeItem(at: url) }
                catch { Issue.record(error) }
            }
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
            buffer.frameLength = buffer.frameCapacity
            let data = try #require(buffer.floatChannelData)
            for frame in 0..<44_100 {
                data[0][frame] = Float(sin(2 * Double.pi * 440 * Double(frame) / 44_100)) * 0.2
            }
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
                file.close()
            }
            let sound = try Sample(file: url).rhythm("x x x x").gain(0.2)
            let loop = try LoopRenderer().render(SoundCompiler().compile(sound), bpm: 120, beatsPerBar: 4)
            let engine = try AudioLoopEngine()
            defer { engine.stop() }
            engine.beginUpdate(revision: 41)
            try engine.submit(loop: loop, revision: 41)
            try engine.play()
            try await Task.sleep(for: .milliseconds(350))
            #expect(engine.outputMeter().interleavedSamples.contains { abs($0) > 0.0001 })
            engine.beginUpdate(revision: 42)
            let missing = url.appendingPathExtension("missing")
            #expect(throws: SampleLoadingError.unreadableFile(missing)) {
                try LoopRenderer().render(SoundCompiler().compile(Sample(file: missing)), bpm: 120, beatsPerBar: 4)
            }
            #expect(engine.snapshot().revision == 41)
            #expect(engine.snapshot().isPlaying)
        }

        @MainActor
        @Test(.timeLimit(.minutes(3)))
        func configuredSourceReachesHardwareTapAndPreservesRevision() async throws {
            let envelope = try Envelope(attack: .milliseconds(10), decay: .milliseconds(20),
                                        sustainLevel: 0.7, release: .milliseconds(50))
            let sound = Synthesizer(.sine).notes("A4 A4 A4 A4")
                .transpose(PitchPattern("0.5 -0.5"))
                .lowPass("800 1600").envelope(envelope).gain(0.1).voicePolicy(.monophonic)
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
