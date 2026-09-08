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

        @MainActor
        @Test(.timeLimit(.minutes(5)))
        func performanceCandidatesRequireAdoptionAndRecoverFromInvalidBodies() async throws {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let evaluator = SourceEvaluator(packageURL: package,
                workspace: package.appending(path: ".build/evaluator-integration"),
                swiftExecutable: "/usr/bin/swift")
            let source = Self.source.replacingOccurrences(
                of: "Synthesizer(.sine).notes(\"C4\").gain(state.gain).position(state.position)",
                with: """
                Synthesizer(.sine).notes("C4").gain(state.gain).position(state.position)
                    .gain(state.gain == 0.9 ? GainPattern("oops") : GainPattern("1"))
                if state.gain > 0.5 {
                    Synthesizer(.sine).notes("G4").gain(0.1)
                }
                """)
            func values(gain: Double, bpm: Double = 120) -> [String: PerformanceControlValue] {
                ["gain": .double(gain), "tempo": .double(bpm),
                 "position": .position(.init(x: 0.5, depth: 0.5))]
            }
            do {
                let initial = try await evaluator.evaluateRetained(source: source,
                    bpm: 123, beatsPerBar: 4, revision: 201)
                #expect(await evaluator.adopt(revision: 201))
                let candidate = try await evaluator.renderPerformance(
                    values: values(gain: 0.6), revision: 201, generation: 1)
                #expect(candidate.loop.bpm == 120)
                #expect(candidate.loop.rows.count == 2)
                #expect(candidate.performanceControls.first { $0.controlID == "gain" }?.value == .double(0.6))
                let lines = source.components(separatedBy: "\n")
                let expectedLines = lines.enumerated().compactMap { index, line in
                    line.contains("GainPattern(\"oops\")") || line.contains("notes(\"G4\")") ? index + 1 : nil
                }
                #expect(candidate.loop.rows.compactMap(\.resultLine) == expectedLines)
                await evaluator.discardPerformance(revision: 201, generation: 1)
                let unchanged = try await evaluator.render(overrides: [], revision: 201, generation: 1)
                #expect(unchanged == initial.loop)
                #expect(await evaluator.adoptPerformance(revision: 201, generation: 1) == false)

                let next = try await evaluator.renderPerformance(
                    values: values(gain: 0.7), revision: 201, generation: 2)
                #expect(await evaluator.adoptPerformance(revision: 201, generation: 2))
                #expect(await evaluator.adoptPerformance(revision: 201, generation: 2))
                let adopted = try await evaluator.render(overrides: [], revision: 201, generation: 2)
                #expect(adopted == next.loop)
                #expect(await evaluator.confirmPerformance(revision: 201, generation: 2))
                do {
                    _ = try await evaluator.renderPerformance(
                        values: values(gain: 0.9), revision: 201, generation: 3)
                    Issue.record("Invalid performance body must fail without adoption")
                } catch EvaluationError.compilerDiagnostic(let message, _) {
                    #expect(!message.isEmpty)
                } catch {
                    Issue.record("Expected a located compiler diagnostic, received: \(error)")
                }
                #expect(await evaluator.controlsAvailable(revision: 201))
                let retained = try await evaluator.render(overrides: [], revision: 201, generation: 3)
                #expect(retained == adopted)
                let recovered = try await evaluator.renderPerformance(
                    values: values(gain: 0.4, bpm: 100), revision: 201, generation: 4)
                #expect(recovered.loop.bpm == 100)
                #expect(recovered.loop.rows.count == 1)
                await evaluator.discardPerformance(revision: 201, generation: 4)
                let hotEdit = try await evaluator.evaluateRetained(source: source + "\n",
                    bpm: 123, beatsPerBar: 4, revision: 202)
                #expect(hotEdit.performanceTransferIssue == nil)
                #expect(hotEdit.loop.bpm == 120)
                #expect(hotEdit.performanceControls.first { $0.controlID == "gain" }?.value == .double(0.7))
                #expect(await evaluator.adopt(revision: 202))
                _ = try await evaluator.renderPerformance(values: values(gain: 0.4, bpm: 100),
                    revision: 202, generation: 1)
                let pendingEdit = try await evaluator.evaluateRetained(source: source + "\n\n",
                    bpm: 123, beatsPerBar: 4, revision: 203)
                #expect(pendingEdit.loop.bpm == 120)
                #expect(pendingEdit.performanceControls.first { $0.controlID == "gain" }?.value == .double(0.7))
                let mismatch = try await evaluator.evaluateRetained(
                    source: source.replacingOccurrences(of: "range: 0...1", with: "range: 0...0.8"),
                    bpm: 123, beatsPerBar: 4, revision: 204)
                #expect(mismatch.performanceTransferIssue != nil)
                #expect(mismatch.loop.bpm == 90)
                #expect(mismatch.performanceControls.first { $0.controlID == "gain" }?.value == .double(0.2))
                try await evaluator.shutdown()
            } catch {
                try await evaluator.shutdown()
                throw error
            }
        }

        @MainActor
        @Test(.timeLimit(.minutes(5)))
        func realWorkerCancellationWaitsForRollbackAndFatalBodyKeepsTransferSnapshot() async throws {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let root = FileManager.default.temporaryDirectory.appending(path: "PerformanceCancellation-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                do { try FileManager.default.removeItem(at: root) }
                catch { Issue.record("Fixture cleanup failed: \(error)") }
            }
            let marker = root.appending(path: "entered")
            let finished = root.appending(path: "finished")
            let source = Self.source.replacingOccurrences(of: "var body: some Sound {", with: """
            @MainActor private func checkLiveState() {
                if state.gain == 0.8 {
                    do {
                        try Data().write(to: URL(fileURLWithPath: "\(marker.path)"))
                        Thread.sleep(forTimeInterval: 0.5)
                        try Data().write(to: URL(fileURLWithPath: "\(finished.path)"))
                    } catch { fatalError("Fixture marker failed") }
                }
                if state.gain == 0.95 { fatalError("Injected performance body trap") }
            }
            var body: some Sound {
                let _ = checkLiveState()
            """)
            let evaluator = SourceEvaluator(packageURL: package,
                workspace: package.appending(path: ".build/evaluator-integration"), swiftExecutable: "/usr/bin/swift")
            func values(_ gain: Double) -> [String: PerformanceControlValue] {
                ["gain": .double(gain), "tempo": .double(120), "position": .position(.init(x: 0, depth: 0))]
            }
            do {
                _ = try await evaluator.evaluateRetained(source: source, bpm: 120, beatsPerBar: 4, revision: 301)
                #expect(await evaluator.adopt(revision: 301))
                let accepted = try await evaluator.renderPerformance(values: values(0.7), revision: 301, generation: 1)
                #expect(await evaluator.adoptPerformance(revision: 301, generation: 1))
                #expect(await evaluator.confirmPerformance(revision: 301, generation: 1))
                let changing = Task {
                    try await evaluator.renderPerformance(values: values(0.8), revision: 301, generation: 2)
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(FileManager.default.fileExists(atPath: marker.path))
                changing.cancel()
                do { _ = try await changing.value; Issue.record("Cancelled model change succeeded") }
                catch is CancellationError { }
                #expect(FileManager.default.fileExists(atPath: finished.path))
                #expect(await evaluator.controlsAvailable(revision: 301))
                let retained = try await evaluator.render(overrides: [], revision: 301, generation: 1)
                #expect(retained == accepted.loop)
                do {
                    _ = try await evaluator.renderPerformance(values: values(0.95), revision: 301, generation: 3)
                    Issue.record("A body trap must terminate its worker")
                } catch EvaluationError.processFailed { }
                #expect(await evaluator.controlsAvailable(revision: 301) == false)
                let recovered = try await evaluator.evaluateRetained(source: Self.source,
                    bpm: 90, beatsPerBar: 4, revision: 302)
                #expect(recovered.loop.bpm == 120)
                #expect(recovered.performanceControls.first { $0.controlID == "gain" }?.value == .double(0.7))
                #expect(await evaluator.adopt(revision: 302))
                try await evaluator.shutdown()
            } catch {
                try await evaluator.shutdown()
                throw error
            }
        }

        @MainActor
        @Test(.timeLimit(.minutes(5)))
        func performanceOverlaysKeepTheirCompiledOwners() async throws {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let source = Self.source.replacingOccurrences(of: "var body: some Sound {", with: """
            var body: some Sound {
                if state.gain > 0.5 {
                    Synthesizer(.sine).notes("G4")
                }
            """)
            let evaluator = SourceEvaluator(packageURL: package,
                workspace: package.appending(path: ".build/evaluator-integration"), swiftExecutable: "/usr/bin/swift")
            let mute = LiveControlOverride(
                address: .init(revision: 401, target: .source(0), parameter: .gain), value: .number(0))
            func values(_ gain: Double) -> [String: PerformanceControlValue] {
                ["gain": .double(gain), "tempo": .double(100),
                 "position": .position(.init(x: -0.5, depth: 0))]
            }
            do {
                _ = try await evaluator.evaluateRetained(source: source, bpm: 120, beatsPerBar: 4, revision: 401)
                #expect(await evaluator.adopt(revision: 401))
                let compatible = try await evaluator.renderPerformance(values: values(0.4),
                    overrides: [mute], revision: 401, generation: 1)
                #expect(compatible.loop.samples.allSatisfy { abs($0) < 0.000001 })
                #expect(compatible.loop.bpm == 100)
                #expect(await evaluator.adoptPerformance(revision: 401, generation: 1))
                #expect(await evaluator.confirmPerformance(revision: 401, generation: 1))
                do {
                    _ = try await evaluator.renderPerformance(values: values(0.6),
                        overrides: [mute], revision: 401, generation: 2)
                    Issue.record("An override must not retarget the newly inserted source zero")
                } catch EvaluationError.invalidResult(let message) {
                    #expect(message.contains("graph identity changed"))
                }
                #expect(await evaluator.controlsAvailable(revision: 401))
                let retained = try await evaluator.render(overrides: [mute], revision: 401, generation: 1)
                #expect(retained == compatible.loop)
                let changed = try await evaluator.renderPerformance(values: values(0.6),
                    revision: 401, generation: 3)
                #expect(changed.loop.rows.count == 2)
                #expect(changed.loop.samples.contains { abs($0) > 0.001 })
                await evaluator.discardPerformance(revision: 401, generation: 3)
                try await evaluator.shutdown()
            } catch {
                try await evaluator.shutdown()
                throw error
            }
        }
    }
}
