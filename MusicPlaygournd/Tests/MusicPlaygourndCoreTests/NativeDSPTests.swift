import Foundation
import XCTest
@testable import MusicPlaygourndCore

@MainActor
final class NativeDSPTests: XCTestCase {
    private let sampleRate = 44_100.0

    func testLiveRateChangesTimingWithoutChangingPitchOrRevision() throws {
        let engine = try makeEngine { time in
            let phase = time.truncatingRemainder(dividingBy: 0.5)
            return phase < 0.15 ? Float(sin(time * 2 * .pi * 440)) * 0.4 : 0
        }
        defer { engine.stop() }
        let normal = try render(engine, seconds: 2)
        try engine.setPlaybackRate(2)
        let fast = try render(engine, seconds: 2)
        XCTAssertEqual(engine.snapshot().revision, 1)
        let normalOnsets = onsets(normal)
        let fastOnsets = onsets(fast)
        XCTAssertGreaterThanOrEqual(normalOnsets.count, 3)
        XCTAssertGreaterThanOrEqual(fastOnsets.count, 5)
        XCTAssertEqual(medianSpacing(normalOnsets), 0.5, accuracy: 0.035)
        XCTAssertEqual(medianSpacing(fastOnsets), 0.25, accuracy: 0.035)
        let pitch = measuredPitch(fast)
        XCTAssertEqual(pitch, 440, accuracy: 12)
    }

    func testLiveLowPassAttenuatesHighFrequenciesAndBypassRestoresThem() throws {
        let engine = try makeEngine { Float(sin($0 * 2 * .pi * 6_000)) * 0.4 }
        defer { engine.stop() }
        let dry = rms(try render(engine, seconds: 0.5).suffix(8_192))
        try engine.setLowPass(cutoff: 400)
        let filtered = rms(try render(engine, seconds: 0.5).suffix(8_192))
        try engine.setLowPass(cutoff: nil)
        let restored = rms(try render(engine, seconds: 0.5).suffix(8_192))
        XCTAssertEqual(dry, 0.4 / sqrt(2), accuracy: 0.01)
        XCTAssertLessThan(filtered, dry * 0.05)
        XCTAssertEqual(restored, dry, accuracy: dry * 0.08)
        XCTAssertEqual(engine.snapshot().revision, 1)
    }

    func testNativeDelayAndReverbProduceTailsBeyondTheDryVoice() throws {
        func voice(_ time: Double) -> Float {
            time < 0.08 ? Float(sin(time * 2 * .pi * 880)) * 0.4 : 0
        }
        let dryEngine = try makeEngine(signal: voice)
        let dry = try render(dryEngine, seconds: 1)
        dryEngine.stop()
        let delayEngine = try makeEngine(signal: voice, configure: { try $0.setDelay(mix: 0.7) })
        let delayed = try render(delayEngine, seconds: 1)
        delayEngine.stop()
        let reverbEngine = try makeEngine(signal: voice, configure: { try $0.setReverb(mix: 0.7) })
        let reverberated = try render(reverbEngine, seconds: 1)
        reverbEngine.stop()
        let tail = Int(sampleRate * 0.2)..<Int(sampleRate * 0.9)
        XCTAssertLessThan(rms(dry[tail]), 0.0001)
        XCTAssertGreaterThan(rms(delayed[tail]), 0.005)
        XCTAssertGreaterThan(rms(reverberated[tail]), 0.0002)
    }

    private func makeEngine(signal: (Double) -> Float, configure: (AudioLoopEngine) throws -> Void = { _ in }) throws -> AudioLoopEngine {
        var samples = [Float]()
        samples.reserveCapacity(352_800)
        for frame in 0..<176_400 {
            let value = signal(Double(frame) / sampleRate)
            samples.append(value)
            samples.append(value)
        }
        let loop = PreparedLoop(sampleRate: sampleRate, bpm: 120, beatsPerBar: 4,
            beatCount: 8, samples: samples, events: [])
        let engine = try AudioLoopEngine()
        engine.beginUpdate(revision: 1)
        try engine.submit(loop: loop, revision: 1)
        try configure(engine)
        try engine.prepareOfflineRenderingForTests()
        try engine.play()
        return engine
    }

    private func render(_ engine: AudioLoopEngine, seconds: Double) throws -> [Float] {
        var remaining = Int(seconds * sampleRate)
        var mono: [Float] = []
        mono.reserveCapacity(remaining)
        while remaining > 0 {
            let count = min(4_096, remaining)
            let stereo = try engine.renderOfflineForTests(frameCount: count)
            XCTAssertEqual(stereo.count, count * 2)
            for index in stride(from: 0, to: stereo.count, by: 2) { mono.append(stereo[index]) }
            remaining -= count
        }
        XCTAssertTrue(mono.allSatisfy(\.isFinite))
        return mono
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, samples.count)))
    }

    private func onsets(_ samples: [Float]) -> [Double] {
        let window = 441
        var result: [Double] = []
        var wasActive = false
        for start in stride(from: 0, to: samples.count - window, by: window) {
            let active = rms(samples[start..<start + window]) > 0.08
            if active && !wasActive { result.append(Double(start) / sampleRate) }
            wasActive = active
        }
        return result
    }

    private func medianSpacing(_ times: [Double]) -> Double {
        guard times.count > 1 else { return 0 }
        let intervals = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
        return intervals[intervals.count / 2]
    }

    private func measuredPitch(_ samples: [Float]) -> Double {
        // Ignore the rate-change transient and measure zero crossings inside sounding spans.
        var crossings: [Int] = []
        for index in 4_410..<(samples.count - 1) where samples[index] < 0 && samples[index + 1] >= 0 {
            if abs(samples[index] - samples[index + 1]) > 0.002 { crossings.append(index) }
        }
        let intervals = zip(crossings.dropFirst(), crossings).map { $0 - $1 }.filter { (50...150).contains($0) }.sorted()
        guard !intervals.isEmpty else { return 0 }
        return sampleRate / Double(intervals[intervals.count / 2])
    }
}
