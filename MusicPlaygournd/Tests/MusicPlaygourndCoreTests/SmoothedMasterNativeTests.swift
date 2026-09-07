import Foundation
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
    @MainActor
    struct SmoothedMasterNativeTests {
        @Test(.timeLimit(.minutes(3)))
        func nativeTargetsRampWithoutLosingRevisionOrBoundaryAdoption() async throws {
            let clock = MasterParameterSmootherTests.StepClock()
            let engine = try makeEngine(clock: clock)
            defer { engine.stop(); clock.finish() }
            _ = try engine.renderOfflineForTests(frameCount: 4_096)
            let initialPosition = engine.snapshot().beatPosition
            try engine.setPlaybackRate(2)
            try engine.setLowPass(cutoff: 500)
            try engine.setDelay(mix: 0.6)
            try engine.setReverb(mix: 0.3)
            #expect(engine.masterParametersForTests.rate == 1)
            #expect(engine.snapshot().beatPosition == initialPosition)
            for step in 1...3 {
                try await waitUntil { clock.pendingCount == 4 }
                for _ in 0..<4 { clock.advance() }
                let fraction = Float(step) / 3
                try await waitUntil {
                    let value = engine.masterParametersForTests
                    return abs(value.rate - (1 + fraction)) < 0.00001
                        && abs(value.delay - 0.6 * fraction) < 0.00001
                        && abs(value.reverb - 0.3 * fraction) < 0.00001
                        && abs((value.lowPass ?? 0) - (20_000 - 19_500 * fraction)) < 0.01
                }
                let values = engine.masterParametersForTests
                #expect(abs(values.delay - 0.6 * fraction) < 0.00001)
                #expect(abs(values.reverb - 0.3 * fraction) < 0.00001)
                #expect(abs((values.lowPass ?? 0) - (20_000 - 19_500 * fraction)) < 0.01)
                #expect(engine.snapshot().revision == 1)
            }
            #expect(throws: PlaybackError.self) { try engine.setPlaybackRate(.nan) }
            #expect(throws: PlaybackError.self) { try engine.setLowPass(cutoff: .infinity) }
            #expect(engine.masterParametersForTests.rate == 2)
            #expect(engine.masterParametersForTests.lowPass == 500)

            engine.beginUpdate(revision: 2)
            try engine.submit(loop: tone(), revision: 2)
            try engine.setPlaybackRate(1.5)
            try await waitUntil { clock.pendingCount == 1 }
            clock.advance()
            try await waitUntil { engine.masterParametersForTests.rate < 2 }
            for _ in 0..<64 where engine.snapshot().revision == 1 {
                _ = try engine.renderOfflineForTests(frameCount: 4_096)
            }
            #expect(engine.snapshot().revision == 2)
            #expect(engine.snapshot().isPlaying)
            engine.stop()
            #expect(engine.masterParametersForTests.rate == 1.5)
            #expect(!engine.snapshot().isPlaying)
            clock.finish()
            await Task.yield()
            #expect(engine.masterParametersForTests.rate == 1.5)
        }

        @Test(.timeLimit(.minutes(3)))
        func filterRampHasIntermediateNativePCMAndDelayedBypass() async throws {
            let clock = MasterParameterSmootherTests.StepClock()
            let engine = try makeEngine(clock: clock)
            defer { engine.stop(); clock.finish() }
            _ = try engine.renderOfflineForTests(frameCount: 4_096)
            let dry = try rms(engine)
            try engine.setLowPass(cutoff: 400)
            var levels: [Double] = []
            for step in 1...3 {
                try await waitUntil { clock.pendingCount == 1 }
                clock.advance()
                let target = 20_000 - 19_600 * Float(step) / 3
                try await waitUntil { abs((engine.masterParametersForTests.lowPass ?? 0) - target) < 0.01 }
                levels.append(try rms(engine))
            }
            #expect(levels[0] > dry * 0.7)
            #expect(levels[2] < dry * 0.05)
            #expect(levels[0] > levels[2] * 10)
            try engine.setLowPass(cutoff: nil)
            #expect(engine.masterParametersForTests.lowPass != nil)
            for step in 1...3 {
                try await waitUntil { clock.pendingCount == 1 }
                clock.advance()
                if step == 3 {
                    try await waitUntil { engine.masterParametersForTests.lowPass == nil }
                } else {
                    let target = 400 + 19_600 * Float(step) / 3
                    try await waitUntil { abs((engine.masterParametersForTests.lowPass ?? 0) - target) < 0.01 }
                    #expect(engine.masterParametersForTests.lowPass != nil)
                }
            }
            #expect(abs(try rms(engine) - dry) < dry * 0.1)
        }

        private func makeEngine(clock: MasterParameterSmootherTests.StepClock) throws -> AudioLoopEngine {
            let smoother = MasterParameterSmoother(sleep: clock.sleep)
            let engine = try AudioLoopEngine(parameterSmoother: smoother)
            engine.beginUpdate(revision: 1)
            try engine.submit(loop: tone(), revision: 1)
            try engine.prepareOfflineRenderingForTests()
            try engine.play()
            return engine
        }

        private func tone() -> PreparedLoop {
            var samples = [Float](repeating: 0, count: 88_200 * 2)
            for frame in 0..<88_200 {
                let value = Float(sin(Double(frame) / 44_100 * 2 * .pi * 6_000)) * 0.3
                samples[frame * 2] = value
                samples[frame * 2 + 1] = value
            }
            return PreparedLoop(sampleRate: 44_100, bpm: 120, beatsPerBar: 4,
                                beatCount: 4, samples: samples, events: [])
        }

        private func rms(_ engine: AudioLoopEngine) throws -> Double {
            _ = try engine.renderOfflineForTests(frameCount: 4_096)
            let samples = try engine.renderOfflineForTests(frameCount: 4_096)
            return sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        }

        private enum ScenarioError: Error { case clockTimeout }

        private func waitUntil(_ condition: () -> Bool) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while !condition() {
                guard clock.now < deadline else { throw ScenarioError.clockTimeout }
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }
}
