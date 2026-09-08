import Darwin
import Foundation
import Testing
import SwiftMusic
@testable import MusicPlaygourndCore

extension NativeHostTests {
struct RenderWorkerConnectionTests {
    @Test(.timeLimit(.minutes(1)))
    func closedProtocolWithOpenDiagnosticsIsBoundedAfterReadiness() async throws {
        let fixture = try makeFixture(mode: .closedOutput)
        let connection = try RenderWorkerConnection(executable: fixture.executable,
            outputURL: fixture.workspace.appending(path: "prepared.plist"), revision: 12)
        let pid = try await fixture.pid()
        _ = try await connection.ready()
        let deadline = ContinuousClock.now.advanced(by: .seconds(14))
        while await connection.isAvailable, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await connection.isAvailable == false)
        await connection.shutdown()
        try await fixture.waitUntilGone(pid)
        try fixture.remove()
    }

    @Test(.timeLimit(.minutes(1)))
    func protocolClosureDrainsDelayedCompilerDiagnosticBeforeFailure() async throws {
        let fixture = try makeFixture(mode: .delayedDiagnostic)
        let connection = try RenderWorkerConnection(executable: fixture.executable,
            outputURL: fixture.workspace.appending(path: "prepared.plist"), revision: 12)
        let pid = try await fixture.pid()
        do {
            _ = try await connection.ready()
            Issue.record("A failed compiler must not publish readiness")
        } catch let error as EvaluationError {
            if case .workerCompilerDiagnostic(let diagnostic) = error {
                #expect(diagnostic.revision == 12)
                #expect(diagnostic.patternText == "1 nope")
                #expect(diagnostic.utf8Offset == 2)
            } else { Issue.record("Lost delayed diagnostic: \(error)") }
        }
        await connection.shutdown()
        try await fixture.waitUntilGone(pid)
        try fixture.remove()
    }

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

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func explicitExportCancellationDoesNotCancelLaterRender(shutdown: Bool) async throws {
        let fixture = try makeFixture(mode: .exportCancellation)
        let connection = try RenderWorkerConnection(
            executable: fixture.executable,
            outputURL: fixture.workspace.appending(path: "prepared.plist"),
            revision: 18
        )
        let pid = try await fixture.pid()
        do {
            let initial = try await connection.ready()
            let destination = fixture.workspace.deletingLastPathComponent()
                .appending(path: "cancelled-stems-\(UUID().uuidString)")
            let export = Task { () throws -> StemExportSnapshot in
                try await connection.exportStems(overrides: [], generation: 0, destination: destination)
            }
            try await fixture.waitForMarker("export.read")
            let close = shutdown ? Task { await connection.shutdown() } : nil
            if !shutdown { export.cancel() }
            try await fixture.waitForMarker("cancel.read")
            do {
                _ = try await export.value
                Issue.record("Cancelled stem export unexpectedly succeeded before its commit point")
            } catch is CancellationError {
            } catch {
                Issue.record("Cancelled stem export failed with the wrong error: \(error)")
            }
            if let close { await close.value }
            else {
                let rendered = try await connection.render(overrides: [], generation: 1)
                let retainedLoopMatches = rendered == initial.loop
                #expect(retainedLoopMatches)
                await connection.shutdown()
            }
            try await fixture.waitUntilGone(pid)
            try fixture.remove()
        } catch {
            await connection.shutdown()
            do {
                try await fixture.waitUntilGone(pid)
            } catch {
                Issue.record("Worker cleanup failed: \(error)")
            }
            do {
                try fixture.remove()
            } catch {
                Issue.record("Fixture cleanup failed: \(error)")
            }
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func malformedStemManifestIsRejectedBeforePCMAccess() async throws {
        let fixture = try makeFixture(mode: .malformedManifest)
        let connection = try RenderWorkerConnection(
            executable: fixture.executable,
            outputURL: fixture.workspace.appending(path: "prepared.plist"),
            revision: 19
        )
        let pid = try await fixture.pid()
        do {
            _ = try await connection.ready()
            let destination = fixture.workspace.deletingLastPathComponent()
                .appending(path: "malformed-stems-(UUID().uuidString)")
            let export = Task { () throws -> StemExportSnapshot in
                try await connection.exportStems(overrides: [], generation: 0, destination: destination)
            }
            try await fixture.waitForMarker("export.read")
            do {
                _ = try await export.value
                Issue.record("Malformed stem metadata unexpectedly succeeded")
            } catch let error as EvaluationError {
                #expect(error.localizedDescription.contains("stem"))
            } catch {
                Issue.record("Malformed stem metadata failed with the wrong error: \(error)")
            }
            await connection.shutdown()
            try await fixture.waitUntilGone(pid)
            try fixture.remove()
        } catch {
            await connection.shutdown()
            do {
                try await fixture.waitUntilGone(pid)
            } catch {
                Issue.record("Worker cleanup failed: \(error)")
            }
            do {
                try fixture.remove()
            } catch {
                Issue.record("Fixture cleanup failed: \(error)")
            }
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func malformedPerformanceMetadataIsRejectedBeforeReady() async throws {
        let fixture = try makeFixture(mode: .malformedPerformanceMetadata)
        let connection = try RenderWorkerConnection(
            executable: fixture.executable,
            outputURL: fixture.workspace.appending(path: "prepared.plist"),
            revision: 20
        )
        let pid = try await fixture.pid()
        do {
            _ = try await connection.ready()
            Issue.record("Malformed performance metadata unexpectedly initialized")
        } catch let error as EvaluationError {
            #expect(error.localizedDescription.contains("performance-control metadata"))
        } catch {
            Issue.record("Malformed performance metadata failed with the wrong error: \(error)")
        }
        await connection.shutdown()
        try await fixture.waitUntilGone(pid)
        try fixture.remove()
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["cancel", "timeout", "badAck"])
    func performanceProtocolCancellationAndFatalBoundaries(mode: String) async throws {
        let fixture = try makeFixture(mode: mode == "cancel" ? .performanceCancelled
            : mode == "timeout" ? .performanceUnresponsive : .performanceBadAck)
        let connection = try RenderWorkerConnection(executable: fixture.executable,
            outputURL: fixture.workspace.appending(path: "prepared.plist"), revision: 21)
        let pid = try await fixture.pid()
        do {
            _ = try await connection.ready()
            let render = Task {
                try await connection.renderPerformance(values: ["gain": .double(0.7)], overrides: [], generation: 1)
            }
            try await fixture.waitForMarker("performance.read")
            if mode == "cancel" {
                render.cancel()
                do { _ = try await render.value; Issue.record("Cancelled performance render succeeded") }
                catch is CancellationError { }
                await connection.discardPerformance(generation: 1)
                #expect(await connection.isAvailable)
                try await fixture.waitForMarker("discard.read")
            } else if mode == "timeout" {
                do { _ = try await render.value; Issue.record("Unresponsive performance render succeeded") }
                catch EvaluationError.timedOut { }
                #expect(await connection.isAvailable == false)
            } else {
                _ = try await render.value
                #expect(await connection.adoptPerformance(generation: 1) == false)
                #expect(await connection.isAvailable == false)
            }
            await connection.shutdown()
            try await fixture.waitUntilGone(pid)
            try fixture.remove()
        } catch {
            await connection.shutdown()
            try fixture.remove()
            throw error
        }
    }

    private enum FixtureMode: String {
        case malformed
        case delayedDiagnostic
        case closedOutput
        case delayedLatest
        case exportCancellation
        case malformedManifest
        case malformedPerformanceMetadata
        case performanceCancelled
        case performanceUnresponsive
        case performanceBadAck
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

        func waitForMarker(_ name: String) async throws {
            let marker = workspace.appending(path: name)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !FileManager.default.fileExists(atPath: marker.path) {
                guard ContinuousClock.now < deadline else {
                    throw EvaluationError.timedOut("Worker fixture did not reach marker \(name).")
                }
                try await Task.sleep(for: .milliseconds(10))
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
        case .exportCancellation:
            let loop = PreparedLoop(sampleRate: 44_100, bpm: 120, beatsPerBar: 4, beatCount: 4,
                samples: [Float](repeating: 0, count: 176_400), events: [])
            let catalog = try LiveControlCatalog(descriptors: [.init(
                address: .init(revision: 18, target: .source(0), parameter: .gain),
                label: "Gain", baseline: .scalar(1))])
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(WorkerPreparedResult(revision: 18, generation: 0, loop: loop))
                .write(to: workspace.appending(path: "prepared.plist"))
            try encoder.encode(WorkerPreparedResult(revision: 18, generation: 1, loop: loop))
                .write(to: workspace.appending(path: "latest.plist"))
            try RenderWorkerFraming.encode(RenderWorkerResponse.ready(revision: 18, catalog: catalog))
                .write(to: workspace.appending(path: "ready.frame"))
            try RenderWorkerFraming.encode(RenderWorkerResponse.failed(
                revision: 18, generation: 0, operationID: 1, message: "Stem export cancelled."
            )).write(to: workspace.appending(path: "cancelled.frame"))
            try RenderWorkerFraming.encode(RenderWorkerResponse.rendered(
                revision: 18, generation: 1, operationID: 2
            )).write(to: workspace.appending(path: "rendered.frame"))
            try RenderWorkerFraming.encode(RenderWorkerResponse.shutdownComplete)
                .write(to: workspace.appending(path: "shutdown.frame"))
            let exportMarker = pythonLiteral(workspace.appending(path: "export.read").path)
            let cancelMarker = pythonLiteral(workspace.appending(path: "cancel.read").path)
            script = """
            #!/usr/bin/env python3
            import os, sys, struct, plistlib
            root = \(pythonLiteral(workspace.path))
            \(pidWrite)
            def read_frame():
                header = sys.stdin.buffer.read(4)
                if len(header) != 4: sys.exit(1)
                size = struct.unpack(">I", header)[0]
                payload = sys.stdin.buffer.read(size)
                if len(payload) != size: sys.exit(1)
                return plistlib.loads(payload)
            sys.stdout.buffer.write(open(root + "/ready.frame", "rb").read())
            sys.stdout.buffer.flush()
            assert "exportStems" in read_frame()
            open(\(exportMarker), "w").close()
            cancellation = read_frame()
            assert cancellation["cancelExport"]["operationID"] == 1
            open(\(cancelMarker), "w").close()
            sys.stdout.buffer.write(open(root + "/cancelled.frame", "rb").read())
            sys.stdout.buffer.flush()
            command = read_frame()
            if "shutdown" in command:
                sys.stdout.buffer.write(open(root + "/shutdown.frame", "rb").read())
                sys.stdout.buffer.flush()
                sys.exit(0)
            assert "render" in command
            os.replace(root + "/latest.plist", root + "/prepared.plist")
            sys.stdout.buffer.write(open(root + "/rendered.frame", "rb").read())
            sys.stdout.buffer.flush()
            read_frame()
            """
        case .malformedManifest:
            let loop = PreparedLoop(sampleRate: 44_100, bpm: 120, beatsPerBar: 4, beatCount: 4,
                samples: [Float](repeating: 0, count: 176_400), events: [])
            let catalog = try LiveControlCatalog(descriptors: [.init(
                address: .init(revision: 19, target: .source(0), parameter: .gain),
                label: "Gain", baseline: .scalar(1))])
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(WorkerPreparedResult(revision: 19, generation: 0, loop: loop))
                .write(to: workspace.appending(path: "prepared.plist"))
            try RenderWorkerFraming.encode(RenderWorkerResponse.ready(revision: 19, catalog: catalog))
                .write(to: workspace.appending(path: "ready.frame"))
            try makeMalformedManifestFrame(revision: 19)
                .write(to: workspace.appending(path: "malformed.frame"))
            let exportMarker = pythonLiteral(workspace.appending(path: "export.read").path)
            script = """
            #!/usr/bin/env python3
            import os, sys, struct
            root = \(pythonLiteral(workspace.path))
            \(pidWrite)
            def read_frame():
                header = sys.stdin.buffer.read(4)
                if len(header) != 4: sys.exit(1)
                size = struct.unpack(">I", header)[0]
                payload = sys.stdin.buffer.read(size)
                if len(payload) != size: sys.exit(1)
                return payload
            sys.stdout.buffer.write(open(root + "/ready.frame", "rb").read())
            sys.stdout.buffer.flush()
            read_frame()
            open(\(exportMarker), "w").close()
            sys.stdout.buffer.write(open(root + "/malformed.frame", "rb").read())
            sys.stdout.buffer.flush()
            read_frame()
            """
        case .performanceCancelled, .performanceUnresponsive, .performanceBadAck:
            let loop = PreparedLoop(sampleRate: 44_100, bpm: 120, beatsPerBar: 4, beatCount: 4,
                samples: [Float](repeating: 0, count: 176_400), events: [])
            let catalog = try LiveControlCatalog(descriptors: [])
            let controls = [PerformanceControlMetadata(modelID: "model", controlID: "gain", label: "Gain",
                domain: .double(range: 0...1, role: .scalar), value: .double(0.7))]
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(WorkerPreparedResult(revision: 21, generation: 0, loop: loop))
                .write(to: workspace.appending(path: "prepared.plist"))
            try encoder.encode(WorkerPreparedResult(revision: 21, generation: 1, loop: loop))
                .write(to: workspace.appending(path: "candidate.plist"))
            let responses: [(String, RenderWorkerResponse)] = [
                ("ready", .ready(revision: 21, catalog: catalog, performanceControls: controls)),
                ("render", .performanceRendered(revision: 21, generation: 1, operationID: 1,
                    catalog: catalog, performanceControls: controls)),
                ("discard", .performanceDiscarded(revision: 21, generation: 1, operationID: 2)),
                ("badAck", .performanceAdopted(revision: 21, generation: 2, operationID: 2, accepted: true)),
                ("shutdown", .shutdownComplete)
            ]
            for (name, response) in responses {
                try RenderWorkerFraming.encode(response).write(to: workspace.appending(path: name + ".frame"))
            }
            script = """
            #!/usr/bin/env python3
            import os, sys, struct, time
            root = \(pythonLiteral(workspace.path))
            mode = \(pythonLiteral(mode.rawValue))
            \(pidWrite)
            def read_frame():
                header = sys.stdin.buffer.read(4)
                if len(header) != 4: sys.exit(1)
                size = struct.unpack(">I", header)[0]
                if len(sys.stdin.buffer.read(size)) != size: sys.exit(1)
            def send(name):
                sys.stdout.buffer.write(open(root + "/" + name + ".frame", "rb").read())
                sys.stdout.buffer.flush()
            send("ready")
            read_frame()
            open(root + "/performance.read", "w").close()
            if mode == "performanceUnresponsive":
                time.sleep(60)
            elif mode == "performanceCancelled":
                read_frame()
                open(root + "/discard.read", "w").close()
                send("discard")
                read_frame()
                send("shutdown")
            else:
                os.replace(root + "/candidate.plist", root + "/prepared.plist")
                send("render")
                read_frame()
                send("badAck")
                time.sleep(60)
            """
        case .malformedPerformanceMetadata:
            let loop = PreparedLoop(sampleRate: 44_100, bpm: 120, beatsPerBar: 4, beatCount: 4,
                samples: [Float](repeating: 0, count: 176_400), events: [])
            let catalog = try LiveControlCatalog(descriptors: [])
            let invalidMetadata = PerformanceControlMetadata(
                modelID: "SessionModel",
                controlID: "gain",
                label: "Gain",
                domain: .double(range: 0...1, role: .scalar),
                value: .position(SpatialPosition(x: 0, depth: 0))
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(WorkerPreparedResult(revision: 20, generation: 0, loop: loop))
                .write(to: workspace.appending(path: "prepared.plist"))
            try RenderWorkerFraming.encode(RenderWorkerResponse.ready(
                revision: 20,
                catalog: catalog,
                performanceControls: [invalidMetadata]
            )).write(to: workspace.appending(path: "ready.frame"))
            script = """
            #!/usr/bin/env python3
            import os, sys, time
            \(pidWrite)
            sys.stdout.buffer.write(open(\(pythonLiteral(workspace.appending(path: "ready.frame").path)), "rb").read())
            sys.stdout.buffer.flush()
            time.sleep(60)
            """
        case .closedOutput:
            let loop = PreparedLoop(sampleRate: 44_100, bpm: 120, beatsPerBar: 4, beatCount: 4,
                samples: [Float](repeating: 0, count: 176_400), events: [])
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(WorkerPreparedResult(revision: 12, generation: 0, loop: loop))
                .write(to: workspace.appending(path: "prepared.plist"))
            try RenderWorkerFraming.encode(RenderWorkerResponse.ready(revision: 12,
                catalog: LiveControlCatalog(descriptors: [])))
                .write(to: workspace.appending(path: "ready.frame"))
            script = """
            #!/usr/bin/env python3
            import os, sys, time
            \(pidWrite)
            sys.stdout.buffer.write(open(\(pythonLiteral(workspace.appending(path: "ready.frame").path)), "rb").read())
            sys.stdout.buffer.flush()
            time.sleep(0.1)
            os.close(1)
            time.sleep(60)
            """
        case .delayedDiagnostic:
            let located = LocatedSoundCompilationError(
                underlying: .invalidGainPattern(.invalidToken(token: "nope", index: 1, offset: 2)),
                anchor: SoundSourceAnchor(fileID: "Session.swift", line: 4, column: 33),
                utf8Offset: 2, patternText: "1 nope")
            let data = try WorkerCompilerDiagnostic(revision: 12, error: located).encodedStderrLine()
            try data.write(to: workspace.appending(path: "diagnostic"))
            script = """
            #!/usr/bin/env python3
            import os, sys, time
            \(pidWrite)
            os.close(1)
            time.sleep(1)
            sys.stderr.buffer.write(open(\(pythonLiteral(workspace.appending(path: "diagnostic").path)), "rb").read())
            sys.stderr.buffer.flush()
            sys.exit(1)
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

    private func makeMalformedManifestFrame(revision: UInt64) throws -> Data {
        let stem = try PreparedStem(
            trackID: 0,
            label: "Lead",
            sampleRate: PreparedLoop.requiredSampleRate,
            bpm: 120,
            beatsPerBar: 4,
            beatCount: 4,
            samples: [Float](repeating: 0, count: 176_400)
        )
        let manifest = StemExportManifest(stem: stem, fileName: "0-Lead.wav")
        let response = RenderWorkerResponse.stemsExported(
            revision: revision, generation: 0, operationID: 1, manifest: [manifest]
        )
        let frame = try RenderWorkerFraming.encode(response)
        let payload = Data(frame.dropFirst(RenderWorkerFraming.headerByteCount))
        let propertyList = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil)

        func corrupt(_ value: Any) -> Any {
            if var dictionary = value as? [String: Any] {
                for key in Array(dictionary.keys) {
                    if let child = dictionary[key] {
                        dictionary[key] = corrupt(child)
                    }
                }
                if dictionary["beatCount"] != nil {
                    dictionary["beatCount"] = 1.0e100
                }
                return dictionary
            }
            if let array = value as? [Any] {
                return array.map(corrupt)
            }
            return value
        }

        let corruptedPayload = try PropertyListSerialization.data(
            fromPropertyList: corrupt(propertyList), format: .binary, options: 0
        )
        guard UInt32(exactly: corruptedPayload.count) != nil else {
            throw EvaluationError.invalidResult("Malformed fixture payload is too large.")
        }
        var corruptedFrame = Data()
        let length = UInt32(corruptedPayload.count)
        corruptedFrame.append(UInt8((length >> 24) & 0xff))
        corruptedFrame.append(UInt8((length >> 16) & 0xff))
        corruptedFrame.append(UInt8((length >> 8) & 0xff))
        corruptedFrame.append(UInt8(length & 0xff))
        corruptedFrame.append(corruptedPayload)
        return corruptedFrame
    }

    private func pythonLiteral(_ path: String) -> String {
        "'" + path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}

}
