import SwiftMusic
import XCTest
@testable import MusicPlaygourndCore

final class LiveOutputTests: XCTestCase {
    @MainActor
    func testHardwareTapAndLiveControlsPreserveAdoptedPlayback() async throws {
        let sound = try SoundCompiler().compile(Synthesizer(.sine).notes("C3 C3 C3 C3"))
        let loop = try LoopRenderer().render(sound, bpm: 120, beatsPerBar: 4)
        let engine = try AudioLoopEngine()
        defer { engine.stop() }
        engine.beginUpdate(revision: 1)
        try engine.submit(loop: loop, revision: 1)
        try engine.play()
        try await Task.sleep(for: .milliseconds(350))
        let first = engine.outputMeter()
        XCTAssertEqual(first.interleavedSamples.count, 4_096)
        XCTAssertGreaterThan(first.sampleRate, 0)
        XCTAssertGreaterThan(first.interleavedSamples.map { abs($0) }.max() ?? 0, 0.0001)
        try engine.setPlaybackRate(137.0 / 120.0)
        try engine.setLowPass(cutoff: 800)
        try engine.setDelay(mix: 0.3)
        try engine.setReverb(mix: 0.2)
        engine.beginUpdate(revision: 2)
        XCTAssertThrowsError(try engine.submit(loop: loop, revision: 1))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(engine.snapshot().revision, 1)
        XCTAssertTrue(engine.snapshot().isPlaying)
        let live = engine.outputMeter()
        XCTAssertTrue(live.interleavedSamples.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(live.interleavedSamples.map { abs($0) }.max() ?? 0, 0.0001)
        engine.stop()
        XCTAssertTrue(engine.outputMeter().interleavedSamples.allSatisfy { $0 == 0 })
    }
}
