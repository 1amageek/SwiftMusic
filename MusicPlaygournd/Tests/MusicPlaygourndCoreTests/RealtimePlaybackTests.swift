import AVFoundation
import Foundation
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
    @MainActor
    struct RealtimePlaybackTests {
        @Test(.timeLimit(.minutes(3)))
        func testNativeOfflineGraphRendersAndCapturesPostFXMeter() throws {
            let engine = try AudioLoopEngine()
            let loop = sineLoop()
            engine.beginUpdate(revision: 11)
            try engine.submit(loop: loop, revision: 11)
            try engine.prepareOfflineRenderingForTests()
            try engine.play()

            let rendered = try engine.renderOfflineForTests(frameCount: 4_096)
            #expect(rendered.count == 8_192)
            #expect(rendered.allSatisfy { $0.isFinite })
            #expect(rendered.map { abs($0) }.max() ?? 0 > 0.01)

            let meter = engine.outputMeter()
            #expect(meter.interleavedSamples.count == 4_096)
            #expect(meter.sampleRate == PreparedLoop.requiredSampleRate)
            #expect(meter.interleavedSamples.allSatisfy { $0.isFinite })
            #expect(meter.interleavedSamples.map { abs($0) }.max() ?? 0 > 0.01)

            engine.stop()
            #expect(engine.outputMeter().interleavedSamples.allSatisfy { $0 == 0 })
        }

        private func sineLoop() -> PreparedLoop {
            var samples = [Float](repeating: 0, count: 88_200 * 2)
            for frame in 0..<88_200 {
                let value = Float(sin(Double(frame) * 2 * .pi * 440 / 44_100) * 0.25)
                samples[frame * 2] = value
                samples[frame * 2 + 1] = value
            }
            return PreparedLoop(
                sampleRate: PreparedLoop.requiredSampleRate,
                bpm: 120,
                beatsPerBar: 4,
                beatCount: 4,
                samples: samples,
                events: []
            )
        }

        @Test(.timeLimit(.minutes(3)))
        func testSameRevisionReplacementReachesNativeOutput() throws {
            let engine = try AudioLoopEngine()
            let first = sineLoop()
            engine.beginUpdate(revision: 21)
            try engine.submit(loop: first, revision: 21)
            try engine.prepareOfflineRenderingForTests()
            try engine.play()
            for _ in 0..<2 { _ = try engine.renderOfflineForTests(frameCount: 4_096) }
            let before = try engine.renderOfflineForTests(frameCount: 4_096)
            let replacement = PreparedLoop(sampleRate: first.sampleRate, bpm: first.bpm,
                beatsPerBar: first.beatsPerBar, beatCount: first.beatCount,
                samples: first.samples.map { $0 * 0.2 }, events: first.events, rows: first.rows)
            try engine.replace(loop: replacement, revision: 21, generation: 1)
            for _ in 0..<4 { _ = try engine.renderOfflineForTests(frameCount: 4_096) }
            let after = try engine.renderOfflineForTests(frameCount: 4_096)
            let beforePower = before.reduce(0.0) { $0 + Double($1 * $1) }
            let afterPower = after.reduce(0.0) { $0 + Double($1 * $1) }
            #expect(beforePower > 1)
            #expect(abs(afterPower / beforePower - 0.04) < 0.005)
            #expect(engine.snapshot().revision == 21)
            #expect(engine.snapshot().overrideGeneration == 1)
            engine.stop()
        }

        @Test(.timeLimit(.minutes(3)))
        func testControlsRejectNonFiniteAndOutOfRangeValues() throws {
            let engine = try AudioLoopEngine()
            #expect(throws: (any Error).self) { try engine.setPlaybackRate(.nan) }
            #expect(throws: (any Error).self) { try engine.setPlaybackRate(0) }
            #expect(throws: (any Error).self) { try engine.setPlaybackRate(33) }
            #expect(throws: (any Error).self) { try engine.setLowPass(cutoff: .infinity) }
            #expect(throws: (any Error).self) { try engine.setLowPass(cutoff: 19) }
            #expect(throws: (any Error).self) { try engine.setDelay(mix: .nan) }
            #expect(throws: (any Error).self) { try engine.setDelay(mix: 1.1) }
            #expect(throws: (any Error).self) { try engine.setReverb(mix: -.infinity) }
            #expect(throws: (any Error).self) { try engine.setReverb(mix: -0.1) }
            try engine.setPlaybackRate(1)
            try engine.setLowPass(cutoff: nil)
            try engine.setDelay(mix: 0)
            try engine.setReverb(mix: 0)
        }

        @Test(.timeLimit(.minutes(3)))
        func testLatencyCorrectionKeepsTheTailOfThePreviousLoopVisibleAtWrap() {
            let tail = AudioTransport.correctedLocalBeatPosition(
                accumulatedBeatPosition: 4.1,
                loopBeatCount: 4,
                correction: 0.25
            )
            #expect(abs((tail) - (3.85)) <= 0.000_001)

            let startup = AudioTransport.correctedLocalBeatPosition(
                accumulatedBeatPosition: 0.1,
                loopBeatCount: 4,
                correction: 0.25
            )
            #expect(abs((startup) - (0)) <= 0.000_001)
        }

        @Test(.timeLimit(.minutes(3)))
        func testMeterPreservesHistoryAcrossShortCallbackBlocks() throws {
            let store = OutputMeterStore()
            store.activate()
            store.capture(try makeMeterBuffer(start: 0, count: 1_024))
            store.capture(try makeMeterBuffer(start: 1_024, count: 1_024))

            let snapshot = store.snapshot()
            #expect(snapshot.interleavedSamples.count == OutputMeterStore.sampleCapacity)
            #expect(abs((snapshot.interleavedSamples[0]) - (0)) <= 0.000_001)
            #expect(abs((snapshot.interleavedSamples[2_046]) - (1_023)) <= 0.000_001)
            #expect(abs((snapshot.interleavedSamples[2_048]) - (1_024)) <= 0.000_001)
            #expect(abs((snapshot.interleavedSamples[4_094]) - (2_047)) <= 0.000_001)
            #expect(snapshot.interleavedSamples.allSatisfy { $0.isFinite })

            store.clear()
            #expect(store.snapshot().interleavedSamples.allSatisfy { $0 == 0 })
        }

        private func makeMeterBuffer(start: Int, count: Int) throws -> AVAudioPCMBuffer {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let channels = try #require(buffer.floatChannelData)
            for frame in 0..<count {
                let value = Float(start + frame)
                channels[0][frame] = value
                channels[1][frame] = -value
            }
            return buffer
        }
    }
}
