import Darwin
import Foundation
import MusicPlaygourndCore
import Testing

extension NativeHostTests {
    struct RetainedEvaluationTests {
        @Test(.timeLimit(.minutes(3)))
        func realWorkerEvaluatesOnceAndRetainsScoreAcrossFailureAndRelease() async throws {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let workspace = package.appending(path: ".build/retained-evaluator-integration")
            let counter = FileManager.default.temporaryDirectory.appending(path: "MusicBody-\(UUID().uuidString)")
            let evaluator = SourceEvaluator(packageURL: package, workspace: workspace, swiftExecutable: "/usr/bin/swift")
            let source = """
            struct Session: Music {
                init() throws {
                    print("User output is not a protocol frame")
                    let file = URL(fileURLWithPath: \(counter.path.debugDescription))
                    let count = FileManager.default.fileExists(atPath: file.path)
                        ? try String(contentsOf: file, encoding: .utf8) : ""
                    try (count + "x").write(to: file, atomically: true, encoding: .utf8)
                    try String(ProcessInfo.processInfo.processIdentifier).write(
                        to: file.appendingPathExtension("pid"), atomically: true, encoding: .utf8)
                }
                var body: some Sound {
                    Synthesizer(.sine).notes("A4 A4").gain(0.4)
                }
            }
            """
            do {
                let initial = try await evaluator.evaluateRetained(source: source, bpm: 120, beatsPerBar: 4, revision: 91)
                await evaluator.adopt(revision: 91)
                let address = try #require(initial.catalog.descriptors.first {
                    $0.address.target == .source(0) && $0.address.parameter == .gain
                }?.address)
                let changed = try await evaluator.render(overrides: [.init(address: address, value: .number(0.25))],
                                                         revision: 91, generation: 1)
                #expect(changed.samples.count == initial.loop.samples.count)
                var error: Float = 0
                for (a, b) in zip(changed.samples, initial.loop.samples) { error = max(error, abs(a - b * 0.25)) }
                #expect(error < 0.000001)
                #expect(changed.rows.map(\.resultLine) == initial.loop.rows.map(\.resultLine))
                await #expect(throws: (any Error).self) {
                    try await evaluator.render(overrides: [.init(address: address, value: .number(-1))], revision: 91, generation: 2)
                }
                let released = try await evaluator.render(overrides: [], revision: 91, generation: 3)
                let releasedMatches = released == initial.loop
                #expect(releasedMatches)
                await #expect(throws: (any Error).self) {
                    try await evaluator.evaluateRetained(source: "struct Session: Music {", bpm: 120, beatsPerBar: 4, revision: 92)
                }
                let afterFailedEdit = try await evaluator.render(overrides: [], revision: 91, generation: 4)
                let failedEditPreservesLoop = afterFailedEdit == initial.loop
                #expect(failedEditPreservesLoop)
                let superseded = Task {
                    try await evaluator.render(overrides: [.init(address: address, value: .number(0.5))],
                                               revision: 91, generation: 5)
                }
                try await Task.sleep(for: .milliseconds(20))
                superseded.cancel()
                let latest = try await evaluator.render(overrides: [.init(address: address, value: .number(0.75))],
                                                        revision: 91, generation: 6)
                do { _ = try await superseded.value }
                catch is CancellationError { }
                var latestError: Float = 0
                for (a, b) in zip(latest.samples, initial.loop.samples) {
                    latestError = max(latestError, abs(a - b * 0.75))
                }
                #expect(latestError < 0.000001)
                #expect(try String(contentsOf: counter, encoding: .utf8) == "x")
                _ = try await evaluator.evaluateRetained(source: source, bpm: 120, beatsPerBar: 4, revision: 92)
                let candidatePID = try #require(Int32(String(contentsOf: counter.appendingPathExtension("pid"), encoding: .utf8)))
                await #expect(throws: (any Error).self) {
                    try await evaluator.evaluateRetained(source: String(repeating: "x", count: 65_537),
                                                         bpm: 120, beatsPerBar: 4, revision: 93)
                }
                #expect(await evaluator.adopt(revision: 92) == false)
                #expect(Darwin.kill(candidatePID, 0) == -1 && errno == ESRCH)
                #expect(await evaluator.controlsAvailable(revision: 91))
                let workers = try FileManager.default.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.hasPrefix("Worker-") }
                #expect(workers.count == 1)
                let retainedAfterInvalidInput = try await evaluator.render(overrides: [], revision: 91, generation: 7)
                let retainedMatches = retainedAfterInvalidInput == initial.loop
                #expect(retainedMatches)
                #expect(try String(contentsOf: counter, encoding: .utf8) == "xx")
                try await evaluator.shutdown()
                #expect(!FileManager.default.fileExists(atPath: workspace.path))
                try FileManager.default.removeItem(at: counter)
                try FileManager.default.removeItem(at: counter.appendingPathExtension("pid"))
            } catch {
                try await evaluator.shutdown()
                if FileManager.default.fileExists(atPath: counter.path) { try FileManager.default.removeItem(at: counter) }
                let pidFile = counter.appendingPathExtension("pid")
                if FileManager.default.fileExists(atPath: pidFile.path) { try FileManager.default.removeItem(at: pidFile) }
                throw error
            }
        }
    }
}
