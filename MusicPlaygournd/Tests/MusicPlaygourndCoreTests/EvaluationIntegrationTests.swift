import Foundation
import MusicPlaygourndCore
import XCTest

final class EvaluationIntegrationTests: XCTestCase {
    @MainActor
    func testRealSwiftEvaluationFailureCancellationTimeoutAndRecovery() async throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workspace = package.appending(path: ".build/evaluator-integration")
        let evaluator = SourceEvaluator(packageURL: package, workspace: workspace, swiftExecutable: "/usr/bin/swift")
        let source = """
        struct Session: Music {
            var body: some Sound {
                Track("Kick") { Sample("kick").rhythm("x ~ x ~").gain(0.8) }
                Synthesizer(.sine).notes("C2 Eb2 G2 Bb2").gain(0.2)
            }
        }
        """
        let first = try await evaluator.evaluate(source: source, bpm: 120, beatsPerBar: 4)
        XCTAssertEqual(first.events.count, 6)
        XCTAssertEqual(first.rows.map { $0.anchor?.line }, [3, 4])
        XCTAssertEqual(first.rows.map { $0.patternText }, ["x ~ x ~", "C2 Eb2 G2 Bb2"])
        XCTAssertTrue(first.rows.allSatisfy { $0.anchor?.fileID.hasSuffix("Session.swift") == true })
        XCTAssertTrue(first.rows.allSatisfy { $0.peaks.contains { $0 > 0 } })
        XCTAssertEqual(first.events.compactMap(\.midiNote), [36, 39, 43, 46])
        XCTAssertTrue(first.samples.contains { abs($0) > 0.01 })
        let engine = try AudioLoopEngine()
        engine.beginUpdate(revision: 1)
        try engine.submit(loop: first, revision: 1)
        XCTAssertEqual(engine.snapshot().revision, 1)
        try engine.play()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(engine.snapshot().isPlaying)
        XCTAssertGreaterThan(engine.snapshot().beatPosition, 0)

        engine.beginUpdate(revision: 2)
        do {
            _ = try await evaluator.evaluate(source: source + "\nunknownSymbol", bpm: 120, beatsPerBar: 4)
            XCTFail("Invalid Swift must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Session.swift")) }
        XCTAssertEqual(engine.snapshot().revision, 1)
        XCTAssertTrue(engine.snapshot().isPlaying)
        do {
            _ = try await evaluator.evaluate(source: source.replacingOccurrences(of: "x ~ x ~", with: "x ?"), bpm: 120, beatsPerBar: 4)
            XCTFail("Invalid music must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("invalidRhythm")) }
        XCTAssertEqual(engine.snapshot().revision, 1)

        let stuck = """
        func stuck() -> Sample { while true {} }
        struct Session: Music { var body: some Sound { stuck() } }
        """
        let cancelled = Task { try await evaluator.evaluate(source: stuck, bpm: 120, beatsPerBar: 4) }
        try await Task.sleep(for: .milliseconds(500))
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancellation must fail") }
        catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        do {
            _ = try await evaluator.evaluate(source: stuck, bpm: 120, beatsPerBar: 4)
            XCTFail("A nonterminating session must time out")
        } catch let error as EvaluationError {
            guard case .timedOut = error else { return XCTFail("Expected timeout, got \(error)") }
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
            XCTFail("Excessive output must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("diagnostic limit")) }
        let logSize = try FileManager.default.attributesOfItem(atPath: workspace.appending(path: "process.log").path)[.size] as? NSNumber
        XCTAssertLessThanOrEqual(logSize?.intValue ?? Int.max, 1_048_576)
        let recovered = try await evaluator.evaluate(source: source, bpm: 60, beatsPerBar: 3)
        XCTAssertEqual(recovered.events.count, first.events.count)
        XCTAssertEqual(recovered.bpm, 60)
        XCTAssertEqual(recovered.beatsPerBar, 3)
        XCTAssertEqual(recovered.beatCount, 6)
        engine.stop()
        engine.beginUpdate(revision: 3)
        try engine.submit(loop: recovered, revision: 3)
        try engine.play()
        XCTAssertEqual(engine.snapshot().revision, 3)
        engine.stop()
        try await evaluator.shutdown()
    }
}
