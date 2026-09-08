import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
    @Suite struct AdvancedSynthesisEvaluationTests {
        @MainActor
        @Test(.timeLimit(.minutes(6)))
        func evaluatedSynthesisFamiliesReachNativePlaybackAndInvalidFMRetainsPCM() async throws {
            let package = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let source = """
            struct Session: Music {
                let pulse: PulseWave
                let frequencyModulation: FrequencyModulation
                let noise: Noise
                let wavetable: Wavetable
                let unison: Unison

                init() {
                    pulse = try! PulseWave(width: 0.35)
                    frequencyModulation = try! FrequencyModulation(ratio: 2, index: 1)
                    noise = Noise(color: .pink, seed: 7)
                    wavetable = try! Wavetable(samples: [0, 1, 0, -1])
                    unison = try! Unison(voices: 3, detuneCents: 18)
                }

                var body: some Sound {
                    Synthesizer(.bandLimitedSaw)
                        .notes("C4")
                        .unison(unison)
                        .gain(0.2)
                        .effect(.saturation(drive: 0.15))
                    Synthesizer(.pulse(pulse))
                        .notes("E4")
                        .gain(0.2)
                        .effect(.delay(time: .sixteenth, feedback: 0.1, wet: 0.2))
                    Synthesizer(.frequencyModulation(frequencyModulation))
                        .notes("C7")
                        .gain(0.15)
                        .effect(.reverb(roomSize: 0.2, wet: 0.1))
                    Synthesizer(.coloredNoise(noise))
                        .gain(0.08)
                        .effect(.filter(kind: .lowPass, cutoffHz: 4_000, resonance: 0.5))
                    Synthesizer(.wavetable(wavetable))
                        .notes("G4")
                        .gain(0.2)
                        .effect(.stereoWidth(0.8))
                }
            }
            """
            let workspace = package.appending(path: ".build/p062-evaluator-\(UUID().uuidString)")
            let evaluator = SourceEvaluator(
                packageURL: package,
                workspace: workspace,
                swiftExecutable: "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
            )
            try await withEvaluatorShutdown(evaluator) {
                let retained = try await evaluator.evaluateRetained(
                    source: source, bpm: 120, beatsPerBar: 4, revision: 621
                )
                #expect(await evaluator.adopt(revision: 621))
                let loop = retained.loop
                #expect(loop.events.count == 5)
                #expect(loop.events.compactMap(\.midiNote) == [60, 64, 96, 60, 67])
                #expect(loop.beatCount == 4)
                #expect(loop.samples.count == 176_400)
                let loopFinite = loop.samples.allSatisfy { $0.isFinite }
                #expect(loopFinite)
                let loopAudible = loop.samples.contains { abs($0) > 0.0001 }
                #expect(loopAudible)

                let engine = try AudioLoopEngine()
                defer { engine.stop() }
                engine.beginUpdate(revision: 621)
                try engine.submit(loop: loop, revision: 621)
                try engine.prepareOfflineRenderingForTests()
                try engine.play()
                let nativePCM = try engine.renderOfflineForTests(frameCount: 4_096)
                #expect(nativePCM.count == 8_192)
                let nativeFinite = nativePCM.allSatisfy { $0.isFinite }
                #expect(nativeFinite)
                let nativeAudible = nativePCM.contains { abs($0) > 0.0001 }
                #expect(nativeAudible)
                #expect(engine.snapshot().revision == 621)
                let adoptedSamples = engine.snapshot().loop?.samples
                let adoptedPCMMatches = adoptedSamples == loop.samples
                #expect(adoptedPCMMatches)

                let invalidSource = source.replacingOccurrences(
                    of: "FrequencyModulation(ratio: 2, index: 1)",
                    with: "FrequencyModulation(ratio: 4, index: 8)"
                )
                var invalidFMFailed = false
                do {
                    _ = try await evaluator.evaluate(source: invalidSource, bpm: 120, beatsPerBar: 4)
                } catch {
                    invalidFMFailed = true
                    #expect(error.localizedDescription.localizedCaseInsensitiveContains("Nyquist"))
                }
                #expect(invalidFMFailed)
                #expect(engine.snapshot().revision == 621)
                let retainedPCM = engine.snapshot().loop?.samples == adoptedSamples
                #expect(retainedPCM)

                let restored = try await evaluator.render(overrides: [], revision: 621, generation: 2)
                let restoredMatches = restored == loop
                #expect(restoredMatches)
                try engine.replace(loop: restored, revision: 621, generation: 2)
                #expect(engine.snapshot().revision == 621)
                #expect(engine.snapshot().overrideGeneration == 2)
            }
        }

        @MainActor
        private func withEvaluatorShutdown(
            _ evaluator: SourceEvaluator,
            operation: () async throws -> Void
        ) async throws {
            do {
                try await operation()
                try await evaluator.shutdown()
            } catch {
                do { try await evaluator.shutdown() }
                catch { Issue.record(error) }
                throw error
            }
        }
    }
}
