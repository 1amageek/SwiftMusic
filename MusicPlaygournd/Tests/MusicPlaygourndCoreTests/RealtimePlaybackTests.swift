import AVFoundation
import Foundation
import XCTest
@testable import MusicPlaygourndCore

@MainActor
final class RealtimePlaybackTests: XCTestCase {
    func testNativeOfflineGraphRendersAndCapturesPostFXMeter() throws {
        let engine = try AudioLoopEngine()
        let loop = sineLoop()
        engine.beginUpdate(revision: 11)
        try engine.submit(loop: loop, revision: 11)
        try engine.prepareOfflineRenderingForTests()
        try engine.play()

        let rendered = try engine.renderOfflineForTests(frameCount: 4_096)
        XCTAssertEqual(rendered.count, 8_192)
        XCTAssertTrue(rendered.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(rendered.map { abs($0) }.max() ?? 0, 0.01)

        let meter = engine.outputMeter()
        XCTAssertEqual(meter.interleavedSamples.count, 4_096)
        XCTAssertEqual(meter.sampleRate, PreparedLoop.requiredSampleRate)
        XCTAssertTrue(meter.interleavedSamples.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(meter.interleavedSamples.map { abs($0) }.max() ?? 0, 0.01)

        engine.stop()
        XCTAssertTrue(engine.outputMeter().interleavedSamples.allSatisfy { $0 == 0 })
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

    func testControlsRejectNonFiniteAndOutOfRangeValues() throws {
        let engine = try AudioLoopEngine()
        XCTAssertThrowsError(try engine.setPlaybackRate(.nan))
        XCTAssertThrowsError(try engine.setPlaybackRate(0))
        XCTAssertThrowsError(try engine.setPlaybackRate(33))
        XCTAssertThrowsError(try engine.setLowPass(cutoff: .infinity))
        XCTAssertThrowsError(try engine.setLowPass(cutoff: 19))
        XCTAssertThrowsError(try engine.setDelay(mix: .nan))
        XCTAssertThrowsError(try engine.setDelay(mix: 1.1))
        XCTAssertThrowsError(try engine.setReverb(mix: -.infinity))
        XCTAssertThrowsError(try engine.setReverb(mix: -0.1))
        try engine.setPlaybackRate(1)
        try engine.setLowPass(cutoff: nil)
        try engine.setDelay(mix: 0)
        try engine.setReverb(mix: 0)
    }

    func testLatencyCorrectionKeepsTheTailOfThePreviousLoopVisibleAtWrap() {
        let tail = AudioTransport.correctedLocalBeatPosition(
            accumulatedBeatPosition: 4.1,
            loopBeatCount: 4,
            correction: 0.25
        )
        XCTAssertEqual(tail, 3.85, accuracy: 0.000_001)

        let startup = AudioTransport.correctedLocalBeatPosition(
            accumulatedBeatPosition: 0.1,
            loopBeatCount: 4,
            correction: 0.25
        )
        XCTAssertEqual(startup, 0, accuracy: 0.000_001)
    }

    func testMeterPreservesHistoryAcrossShortCallbackBlocks() throws {
        let store = OutputMeterStore()
        store.activate()
        store.capture(try makeMeterBuffer(start: 0, count: 1_024))
        store.capture(try makeMeterBuffer(start: 1_024, count: 1_024))

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.interleavedSamples.count, OutputMeterStore.sampleCapacity)
        XCTAssertEqual(snapshot.interleavedSamples[0], 0, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.interleavedSamples[2_046], 1_023, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.interleavedSamples[2_048], 1_024, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.interleavedSamples[4_094], 2_047, accuracy: 0.000_001)
        XCTAssertTrue(snapshot.interleavedSamples.allSatisfy(\.isFinite))

        store.clear()
        XCTAssertTrue(store.snapshot().interleavedSamples.allSatisfy { $0 == 0 })
    }

    private func makeMeterBuffer(start: Int, count: Int) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<count {
            let value = Float(start + frame)
            channels[0][frame] = value
            channels[1][frame] = -value
        }
        return buffer
    }
}
