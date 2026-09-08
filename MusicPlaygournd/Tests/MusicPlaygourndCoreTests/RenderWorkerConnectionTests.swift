import Darwin
import Foundation
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
struct RenderWorkerConnectionTests {
    @Test(.timeLimit(.minutes(3)))
    func malformedFrameFailsWithTypedErrorAndReapsWorker() async throws {
        let fixture = try makeFixture(mode: .malformed)
        let connection = try RenderWorkerConnection(
            executable: fixture.executable,
            outputURL: fixture.workspace.appending(path: "prepared.plist"),
            revision: 12
        )
        let pid = try await fixture.pid()
        do {
            _ = try await connection.ready()
            Issue.record("Malformed worker protocol unexpectedly initialized")
        } catch {
            #expect(error is EvaluationError)
        }
        await connection.shutdown()
        try await fixture.waitUntilGone(pid)
        try fixture.remove()
    }

    @Test(.timeLimit(.minutes(3)))
    func truncatedFrameFailsWithTypedErrorAndReapsWorker() async throws {
        let fixture = try makeFixture(mode: .truncated)
        let connection = try RenderWorkerConnection(
            executable: fixture.executable,
            outputURL: fixture.workspace.appending(path: "prepared.plist"),
            revision: 13
        )
        let pid = try await fixture.pid()
        do {
            _ = try await connection.ready()
            Issue.record("Truncated worker protocol unexpectedly initialized")
        } catch {
            #expect(error is EvaluationError)
        }
        await connection.shutdown()
        try await fixture.waitUntilGone(pid)
        try fixture.remove()
    }

    @Test(.timeLimit(.minutes(3)))
    func cancelledInitializationRemainsBoundedAndReapsWorker() async throws {
        let fixture = try makeFixture(mode: .unresponsive)
        let connection = try RenderWorkerConnection(
            executable: fixture.executable,
            outputURL: fixture.workspace.appending(path: "prepared.plist"),
            revision: 14
        )
        let pid = try await fixture.pid()
        let ready = Task { () throws -> RetainedEvaluation in
            try await connection.ready()
        }
        try await Task.sleep(for: .milliseconds(100))
        ready.cancel()
        do {
            _ = try await ready.value
            Issue.record("Cancelled worker initialization unexpectedly succeeded")
        } catch {
            #expect(error is EvaluationError || error is CancellationError)
        }
        await connection.shutdown()
        try await fixture.waitUntilGone(pid)
        try fixture.remove()
    }

    @Test(.timeLimit(.minutes(1)))
    func unresponsiveInitializationHitsWatchdogAndReapsWorker() async throws {
        let fixture = try makeFixture(mode: .unresponsive)
        let connection = try RenderWorkerConnection(executable: fixture.executable,
            outputURL: fixture.workspace.appending(path: "prepared.plist"), revision: 16)
        let pid = try await fixture.pid()
        let started = ContinuousClock.now
        do {
            _ = try await connection.ready()
            Issue.record("Unresponsive worker unexpectedly initialized")
        } catch let error as EvaluationError {
            guard case .timedOut = error else {
                Issue.record("The watchdog must preserve the typed timeout error")
                await connection.shutdown()
                try fixture.remove()
                return
            }
            #expect(error.localizedDescription.contains("10 seconds"))
        }
        #expect(started.duration(to: .now) < .seconds(15))
        #expect(await connection.isAvailable == false)
        await connection.shutdown()
        try await fixture.waitUntilGone(pid)
        try fixture.remove()
    }

    @Test(.timeLimit(.minutes(3)))
    func shutdownReapsAChildThatReadsTheCommandAndExits() async throws {
        let fixture = try makeFixture(mode: .shutdownAware)
        let connection = try RenderWorkerConnection(
            executable: fixture.executable,
            outputURL: fixture.workspace.appending(path: "prepared.plist"),
            revision: 15
        )
        let pid = try await fixture.pid()
        let ready = Task { () throws -> RetainedEvaluation in
            try await connection.ready()
        }
        try await Task.sleep(for: .milliseconds(100))
        await connection.shutdown()
        ready.cancel()
        _ = await ready.result
        try await fixture.waitUntilGone(pid)
        try fixture.remove()
    }

    @Test(.timeLimit(.minutes(1)))
    func newerGenerationReceivesItsOwnDeadline() async throws {
        let fixture = try makeFixture(mode: .delayedLatest)
        let connection = try RenderWorkerConnection(executable: fixture.executable,
            outputURL: fixture.workspace.appending(path: "prepared.plist"), revision: 17)
        let pid = try await fixture.pid()
        do {
            let initial = try await connection.ready()
            let address = try #require(initial.catalog.descriptors.first?.address)
            let first = Task {
                try await connection.render(overrides: [.init(address: address, value: .number(0.5))], generation: 1)
            }
            try await Task.sleep(for: .milliseconds(8_500))
            let latest = try await connection.render(overrides: [], generation: 2)
            #expect(latest.samples.count == initial.loop.samples.count)
            #expect(await connection.isAvailable)
            do {
                _ = try await first.value
                Issue.record("The first request must be superseded")
            } catch is CancellationError { }
        } catch {
            await connection.shutdown()
            try await fixture.waitUntilGone(pid)
            try fixture.remove()
            throw error
        }
        await connection.shutdown()
        try await fixture.waitUntilGone(pid)
        try fixture.remove()
    }

    private enum FixtureMode: String {
        case malformed
        case delayedLatest
        case truncated
        case unresponsive
        case shutdownAware
    }

    private struct Fixture {
        let workspace: URL
        let executable: URL
        let pidFile: URL

        func pid() async throws -> Int32 {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while true {
                if FileManager.default.fileExists(atPath: pidFile.path) {
                    let text = try String(contentsOf: pidFile, encoding: .utf8)
                    if let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        return value
                    }
                }
                guard ContinuousClock.now < deadline else {
                    throw EvaluationError.invalidResult("Worker fixture did not publish its PID.")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        func waitUntilGone(_ pid: Int32) async throws {
            guard Darwin.kill(pid, 0) == -1, errno == ESRCH else {
                throw EvaluationError.processFailed("shutdown returned before the worker was reaped.")
            }
        }

        func remove() throws {
            try FileManager.default.removeItem(at: workspace)
        }
    }

    private func makeFixture(mode: FixtureMode) throws -> Fixture {
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "RenderWorkerConnection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let executable = workspace.appending(path: "worker.py")
        let pidFile = workspace.appending(path: "pid")
        let pid = pythonLiteral(pidFile.path)
        let pidWrite = "pid_temp = \(pythonLiteral(pidFile.path + ".tmp")); open(pid_temp, \"w\").write(str(os.getpid())); os.replace(pid_temp, \(pid))"
        let script: String
        switch mode {
        case .delayedLatest:
            let loop = PreparedLoop(sampleRate: 44_100, bpm: 120, beatsPerBar: 4, beatCount: 4,
                samples: [Float](repeating: 0, count: 176_400), events: [])
            let catalog = try LiveControlCatalog(descriptors: [.init(
                address: .init(revision: 17, target: .source(0), parameter: .gain),
                label: "Gain", baseline: .scalar(1))])
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(WorkerPreparedResult(revision: 17, generation: 0, loop: loop))
                .write(to: workspace.appending(path: "prepared.plist"))
            try encoder.encode(WorkerPreparedResult(revision: 17, generation: 2, loop: loop))
                .write(to: workspace.appending(path: "latest.plist"))
            try RenderWorkerFraming.encode(RenderWorkerResponse.ready(revision: 17, catalog: catalog))
                .write(to: workspace.appending(path: "ready.frame"))
            try RenderWorkerFraming.encode(RenderWorkerResponse.rendered(revision: 17, generation: 2))
                .write(to: workspace.appending(path: "latest.frame"))
            script = """
            #!/usr/bin/env python3
            import os, sys, time, struct
            root = \(pythonLiteral(workspace.path))
            with open(\(pid) + ".tmp", "w") as f: f.write(str(os.getpid()))
            os.replace(\(pid) + ".tmp", \(pid))
            sys.stdout.buffer.write(open(root + "/ready.frame", "rb").read())
            sys.stdout.buffer.flush()
            def read_frame():
                header = sys.stdin.buffer.read(4)
                if len(header) != 4: sys.exit(1)
                size = struct.unpack(">I", header)[0]
                if len(sys.stdin.buffer.read(size)) != size: sys.exit(1)
            read_frame()
            read_frame()
            time.sleep(2)
            os.replace(root + "/latest.plist", root + "/prepared.plist")
            sys.stdout.buffer.write(open(root + "/latest.frame", "rb").read())
            sys.stdout.buffer.flush()
            read_frame()
            """
        case .malformed:
            script = """
            #!/usr/bin/env python3
            import os, sys, time
            \(pidWrite)
            sys.stdout.buffer.write(b"\\x00\\x00\\x00\\x02xx")
            sys.stdout.buffer.flush()
            time.sleep(60)
            """
        case .truncated:
            script = """
            #!/usr/bin/env python3
            import os, sys, time
            \(pidWrite)
            sys.stdout.buffer.write(b"\\x00\\x00\\x00\\x08xx")
            sys.stdout.buffer.flush()
            """
        case .unresponsive:
            script = """
            #!/usr/bin/env python3
            import os, time
            \(pidWrite)
            time.sleep(60)
            """
        case .shutdownAware:
            script = """
            #!/usr/bin/env python3
            import os, sys
            \(pidWrite)
            sys.stdin.buffer.read(1)
            """
        }
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return Fixture(workspace: workspace, executable: executable, pidFile: pidFile)
    }

    private func pythonLiteral(_ path: String) -> String {
        "'" + path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}

}
