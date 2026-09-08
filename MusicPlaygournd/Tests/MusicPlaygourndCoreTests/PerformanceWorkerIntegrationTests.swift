import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
    struct PerformanceWorkerIntegrationTests {
        private static let source = #"""
        import Observation

        @MainActor @Observable
        final class PerformanceState: PerformanceControllable {
            let performanceModelID = "performance-integration"
            var gain = 0.2
            var tempo = 90.0
            var position = SpatialPosition(x: -0.5, depth: 0)
            var performanceControls: PerformanceControlSet<PerformanceState> {
                get throws {
                    try PerformanceControlSet([
                        .mappedDouble(id: "gain", range: 0...1, keyPath: \PerformanceState.gain),
                        .mappedBPM(id: "tempo", range: 60...180, keyPath: \PerformanceState.tempo),
                        .mappedPosition(id: "position", keyPath: \PerformanceState.position)
                    ])
                }
            }
        }

        struct Session: PerformanceEntry {
            @Performance(PerformanceState.self) private var state
            @MainActor private static var creations = 0
            @MainActor static func makePerformanceModel() -> PerformanceState {
                creations += 1
                let state = PerformanceState()
                state.gain = Double(creations) / 5
                return state
            }
            var body: some Sound {
                Synthesizer(.sine).notes("C4").gain(state.gain).position(state.position)
            }
        }
        """#

        @MainActor
        @Test(.timeLimit(.minutes(5)))
        func factoryModelControlsReachRetainedWorker() async throws {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let evaluator = SourceEvaluator(packageURL: package,
                workspace: package.appending(path: ".build/evaluator-integration"),
                swiftExecutable: "/usr/bin/swift")
            do {
                let ordinary = try await evaluator.evaluateRetained(
                    source: #"struct Session: Music { var body: some Sound { Synthesizer(.sine).notes("C4") } }"#,
                    bpm: 123, beatsPerBar: 4, revision: 100)
                #expect(ordinary.loop.bpm == 123)
                #expect(ordinary.performanceControls.isEmpty)
                #expect(await evaluator.adopt(revision: 100))
                let initial = try await evaluator.evaluateRetained(
                    source: Self.source, bpm: 123, beatsPerBar: 4, revision: 101)
                #expect(initial.performanceControls.map(\.controlID) == ["gain", "tempo", "position"])
                #expect(initial.performanceControls.allSatisfy { $0.modelID == "performance-integration" })
                let tempo = try #require(initial.performanceControls.first { $0.controlID == "tempo" })
                #expect(tempo.value == .double(90))
                let gain = try #require(initial.performanceControls.first { $0.controlID == "gain" })
                #expect(gain.value == .double(0.2))
                #expect(initial.loop.bpm == 90)
                #expect(initial.loop.samples.contains { abs($0) > 0.001 })
                #expect(await evaluator.adopt(revision: 101))
                let faulty = Self.source.replacingOccurrences(of: ".gain(state.gain)", with: #".gain("oops")"#)
                do {
                    _ = try await evaluator.evaluateRetained(source: faulty, bpm: 123, beatsPerBar: 4, revision: 102)
                    Issue.record("Invalid performance body must fail preparation")
                } catch EvaluationError.compilerDiagnostic(_, let range) {
                    let location = try #require(range)
                    #expect((faulty as NSString).substring(with: location.utf16Range) == "oops")
                }
                #expect(await evaluator.controlsAvailable(revision: 101))
                try await evaluator.shutdown()
            } catch {
                try await evaluator.shutdown()
                throw error
            }
        }
    }
}
