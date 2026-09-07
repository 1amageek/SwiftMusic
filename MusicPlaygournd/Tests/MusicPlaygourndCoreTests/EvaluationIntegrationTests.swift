import Foundation
import MusicPlaygourndCore
import Testing

extension NativeHostTests {
    struct EvaluationIntegrationTests {
        @MainActor
        @Test(.timeLimit(.minutes(3)))
        func testRealSwiftEvaluationFailureCancellationTimeoutAndRecovery() async throws {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let workspace = package.appending(path: ".build/evaluator-integration")
            let evaluator = SourceEvaluator(packageURL: package, workspace: workspace, swiftExecutable: "/usr/bin/swift")
            let source = """
            struct Session: Music {
                var body: some Sound {
                    Track("Kick") {
                        Sample("kick") // 🥁 .gain(99)
                            .rhythm("x ~ x ~")
                            .gain(0.8)
                    }.gain(0.5)
                    Synthesizer(.sine)
                        .notes("C2 Eb2 G2 Bb2")
                        .transpose(12)
                        .gain(
                            0.2
                        )
                        .pan("-1 1")
                        .gain("1 0.5")
                }
            }
            """
            let first = try await evaluator.evaluate(source: source, bpm: 120, beatsPerBar: 4)
            #expect(first.events.count == 6)
            #expect(first.rows.map { $0.anchor?.line } == [5, 9])
            #expect(first.rows.map(\.resultLine) == [7, 15])
            #expect(first.rows.map { $0.patternText } == ["x ~ x ~", "C2 Eb2 G2 Bb2"])
            #expect(first.rows.allSatisfy { $0.anchor?.fileID.hasSuffix("Session.swift") == true })
            #expect(first.rows.allSatisfy { $0.peaks.contains { $0 > 0 } })
            #expect(first.events.compactMap(\.midiNote) == [48, 51, 55, 58])
            #expect(first.events.filter { $0.sourceID == 1 }.map(\.pan) == [-1, -1, 1, 1])
            #expect(first.events.filter { $0.sourceID == 1 }.map(\.gain) == [1, 1, 0.5, 0.5])
            #expect(first.samples.contains { abs($0) > 0.01 })
            let engine = try AudioLoopEngine()
            engine.beginUpdate(revision: 1)
            try engine.submit(loop: first, revision: 1)
            #expect(engine.snapshot().revision == 1)
            try engine.play()
            try await Task.sleep(for: .milliseconds(200))
            #expect(engine.snapshot().isPlaying)
            #expect(engine.snapshot().beatPosition > 0)

            engine.beginUpdate(revision: 2)
            do {
                _ = try await evaluator.evaluate(source: source + "\nunknownSymbol", bpm: 120, beatsPerBar: 4)
                Issue.record("Invalid Swift must fail")
            } catch { #expect(error.localizedDescription.contains("Session.swift")) }
            #expect(engine.snapshot().revision == 1)
            #expect(engine.snapshot().isPlaying)
            do {
                _ = try await evaluator.evaluate(source: source.replacingOccurrences(of: "x ~ x ~", with: "x ?"), bpm: 120, beatsPerBar: 4)
                Issue.record("Invalid music must fail")
            } catch { #expect(error.localizedDescription.contains("invalidRhythm")) }
            #expect(engine.snapshot().revision == 1)

            let stuck = """
            func stuck() -> Sample { while true {} }
            struct Session: Music { var body: some Sound { stuck() } }
            """
            let cancelled = Task { try await evaluator.evaluate(source: stuck, bpm: 120, beatsPerBar: 4) }
            try await Task.sleep(for: .milliseconds(500))
            cancelled.cancel()
            do { _ = try await cancelled.value; Issue.record("Cancellation must fail") }
            catch is CancellationError {} catch { Issue.record("Expected cancellation, got \(error)") }
            do {
                _ = try await evaluator.evaluate(source: stuck, bpm: 120, beatsPerBar: 4)
                Issue.record("A nonterminating session must time out")
            } catch let error as EvaluationError {
                guard case .timedOut = error else { Issue.record("Expected timeout, got \(error)"); return }
            }
            let noisy = """
            func noisy() -> Sample {
                print(String(repeating: "z", count: 2_000_000))
                return Sample("kick")
            }
            struct Session: Music { var body: some Sound { noisy() } }
            """
            do {
                _ = try await evaluator.evaluate(source: noisy, bpm: 120, beatsPerBar: 4)
                Issue.record("Excessive output must fail")
            } catch { #expect(error.localizedDescription.contains("diagnostic limit")) }
            let logSize = try FileManager.default.attributesOfItem(atPath: workspace.appending(path: "process.log").path)[.size] as? NSNumber
            #expect(logSize?.intValue ?? Int.max <= 1_048_576)
            let recovered = try await evaluator.evaluate(source: source, bpm: 60, beatsPerBar: 3)
            #expect(recovered.events.count == first.events.count)
            #expect(recovered.bpm == 60)
            #expect(recovered.beatsPerBar == 3)
            #expect(recovered.beatCount == 6)
            engine.stop()
            engine.beginUpdate(revision: 3)
            try engine.submit(loop: recovered, revision: 3)
            try engine.play()
            #expect(engine.snapshot().revision == 3)
            engine.stop()
            let nested = source.replacingOccurrences(of: "x ~ x ~", with: "x [x x] ~ x")
                .replacingOccurrences(of: ".gain(0.8)", with: ".gain(\"1 [0 0.5] 0.2 0.8\")")
            let patterned = try await evaluator.evaluate(source: nested, bpm: 120, beatsPerBar: 4)
            #expect(patterned.events.filter { $0.label == "Kick" }.map(\.gain) == [1, 0, 0.5, 0.8])
            #expect(patterned.events.filter { $0.label == "Kick" }.map(\.startBeat) == [0, 1, 1.5, 3])
            do {
                _ = try await evaluator.evaluate(source: nested.replacingOccurrences(of: "x [x x] ~ x", with: "x [x x ~ x"), bpm: 120, beatsPerBar: 4)
                Issue.record("Unbalanced pattern groups must fail")
            } catch { #expect(!(error.localizedDescription.isEmpty)) }
            try await evaluator.shutdown()
        }
    }
}
