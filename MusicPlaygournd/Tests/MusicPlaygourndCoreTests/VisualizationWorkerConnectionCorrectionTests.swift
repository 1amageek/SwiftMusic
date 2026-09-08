import Darwin
import Foundation
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
    struct VisualizationWorkerConnectionCorrectionTests {
        @Test(.timeLimit(.minutes(2)))
        func queuedVisualizationReplacementPreservesChronologicalRenderOrder() async throws {
            let fixture = try Fixture.makeOrdering()
            let connection = try RenderWorkerConnection(
                executable: fixture.executable,
                outputURL: fixture.workspace.appending(path: "prepared.plist"),
                revision: 22
            )
            let pid = try await fixture.pid()
            do {
                let initial = try await connection.ready()
                let address = try #require(initial.catalog.descriptors.first?.address)
                let fullOverrides = initial.catalog.descriptors.map {
                    LiveControlOverride(address: $0.address, value: .number(0.5))
                }

                let firstRender = Task {
                    try await connection.render(overrides: fullOverrides, generation: 1)
                }
                try await Task.sleep(for: .milliseconds(100))
                let firstVisualization = Task {
                    try await connection.visualization(
                        address: address, overrides: [], selectionGeneration: 2)
                }
                await Task.yield()
                let secondRender = Task {
                    try await connection.render(overrides: [], generation: 3)
                }
                await Task.yield()
                let latestVisualization = Task {
                    try await connection.visualization(
                        address: address, overrides: [], selectionGeneration: 4)
                }
                await Task.yield()
                try fixture.touch("release")

                do {
                    _ = try await firstVisualization.value
                    Issue.record("The superseded visualization unexpectedly succeeded")
                } catch is CancellationError {
                }
                do {
                    _ = try await firstRender.value
                    Issue.record("The superseded prelude render unexpectedly succeeded")
                } catch is CancellationError {
                }
                let secondRendered = try await secondRender.value
                #expect(secondRendered == initial.loop)
                let selected = try await latestVisualization.value
                #expect(selected.address == address)
                #expect(await connection.isAvailable)
                await connection.shutdown()
                try await fixture.waitUntilGone(pid)
                try fixture.remove()
            } catch {
                await connection.shutdown()
                do { try await fixture.waitUntilGone(pid) }
                catch { Issue.record("Worker cleanup failed: \(error)") }
                do { try fixture.remove() }
                catch { Issue.record("Fixture cleanup failed: \(error)") }
                throw error
            }
        }

        @Test(.timeLimit(.minutes(2)))
        func queuedVisualizationCancellationReachesWorkerBeforeLatestSelection() async throws {
            let fixture = try Fixture.makeQueuedCancellation()
            let connection = try RenderWorkerConnection(
                executable: fixture.executable,
                outputURL: fixture.workspace.appending(path: "prepared.plist"),
                revision: 24
            )
            let pid = try await fixture.pid()
            do {
                let initial = try await connection.ready()
                let address = try #require(initial.catalog.descriptors.first?.address)
                let firstVisualization = Task {
                    try await connection.visualization(
                        address: address, overrides: [], selectionGeneration: 1)
                }
                try await fixture.waitForMarker("visualize1.received")

                let latestVisualization = Task {
                    try await connection.visualization(
                        address: address, overrides: [], selectionGeneration: 2)
                }
                await Task.yield()

                do {
                    _ = try await firstVisualization.value
                    Issue.record("The received visualization unexpectedly succeeded")
                } catch is CancellationError {
                }
                let selected = try await latestVisualization.value
                #expect(selected.address == address)
                #expect(FileManager.default.fileExists(
                    atPath: fixture.workspace.appending(path: "cancel1.received").path))
                #expect(await connection.isAvailable)
                let retainedPCM = initial.loop.samples.allSatisfy { $0 == 0 }
                #expect(retainedPCM)
                await connection.shutdown()
                try await fixture.waitUntilGone(pid)
                try fixture.remove()
            } catch {
                await connection.shutdown()
                do { try await fixture.waitUntilGone(pid) }
                catch { Issue.record("Worker cleanup failed: \(error)") }
                do { try fixture.remove() }
                catch { Issue.record("Fixture cleanup failed: \(error)") }
                throw error
            }
        }

        @Test(.timeLimit(.minutes(2)))
        func malformedVisualizationFailsTypedAndLeavesPreparedPCMValueIntact() async throws {
            let fixture = try Fixture.makeMalformedVisualization()
            let connection = try RenderWorkerConnection(
                executable: fixture.executable,
                outputURL: fixture.workspace.appending(path: "prepared.plist"),
                revision: 23
            )
            let pid = try await fixture.pid()
            do {
                let initial = try await connection.ready()
                let address = try #require(initial.catalog.descriptors.first?.address)
                do {
                    _ = try await connection.visualization(
                        address: address, overrides: [], selectionGeneration: 1)
                    Issue.record("Malformed visualization unexpectedly succeeded")
                } catch is EvaluationError {
                }
                #expect(await connection.isAvailable == false)
                let retainedPCM = initial.loop.samples.allSatisfy { $0 == 0 }
                #expect(retainedPCM)
                await connection.shutdown()
                try await fixture.waitUntilGone(pid)
                try fixture.remove()
            } catch {
                await connection.shutdown()
                do { try await fixture.waitUntilGone(pid) }
                catch { Issue.record("Worker cleanup failed: \(error)") }
                do { try fixture.remove() }
                catch { Issue.record("Fixture cleanup failed: \(error)") }
                throw error
            }
        }

        private struct Fixture {
            let workspace: URL
            let executable: URL
            let pidFile: URL

            static func makeOrdering() throws -> Self {
                let fixture = try makeWorkspace(name: "VisualizationOrdering")
                let descriptors = (0..<1_024).map { index in
                    LiveControlDescriptor(
                        address: .init(revision: 22, target: .source(index), parameter: .gain),
                        label: "Gain \(index)",
                        baseline: .scalar(1)
                    )
                }
                let catalog = try LiveControlCatalog(descriptors: descriptors)
                let initialLoop = PreparedLoop(
                    sampleRate: 44_100, bpm: 120, beatsPerBar: 4, beatCount: 4,
                    samples: [Float](repeating: 0, count: 176_400), events: [])
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                try encoder.encode(WorkerPreparedResult(
                    revision: 22, generation: 0, loop: initialLoop
                )).write(to: fixture.workspace.appending(path: "prepared.plist"))
                try encoder.encode(WorkerPreparedResult(
                    revision: 22, generation: 1, loop: initialLoop
                )).write(to: fixture.workspace.appending(path: "render1.plist"))
                try encoder.encode(WorkerPreparedResult(
                    revision: 22, generation: 3, loop: initialLoop
                )).write(to: fixture.workspace.appending(path: "render3.plist"))
                try RenderWorkerFraming.encode(
                    RenderWorkerResponse.ready(revision: 22, catalog: catalog)
                ).write(to: fixture.workspace.appending(path: "ready.frame"))
                try RenderWorkerFraming.encode(
                    RenderWorkerResponse.rendered(revision: 22, generation: 1, operationID: 1)
                ).write(to: fixture.workspace.appending(path: "render1.frame"))
                try RenderWorkerFraming.encode(
                    RenderWorkerResponse.rendered(revision: 22, generation: 3, operationID: 3)
                ).write(to: fixture.workspace.appending(path: "render3.frame"))
                guard let address = catalog.descriptors.first?.address else {
                    throw EvaluationError.invalidResult("Visualization fixture catalog is empty.")
                }
                try makeVisualizationFrame(
                    revision: 22, operationID: 4, selectionGeneration: 4, address: address
                ).write(to: fixture.workspace.appending(path: "visualize4.frame"))
                try RenderWorkerFraming.encode(RenderWorkerResponse.shutdownComplete)
                    .write(to: fixture.workspace.appending(path: "shutdown.frame"))
                try fixture.writeScript("""
                #!/usr/bin/env python3
                import os, sys, struct, plistlib
                root = \(pythonLiteral(fixture.workspace.path))
                \(fixture.pidWrite)
                def read_frame():
                    header = sys.stdin.buffer.read(4)
                    if len(header) != 4: sys.exit(1)
                    size = struct.unpack(">I", header)[0]
                    payload = sys.stdin.buffer.read(size)
                    if len(payload) != size: sys.exit(1)
                    return plistlib.loads(payload)
                def emit(name):
                    sys.stdout.buffer.write(open(root + "/" + name, "rb").read())
                    sys.stdout.buffer.flush()
                emit("ready.frame")
                while not os.path.exists(root + "/release"):
                    __import__("time").sleep(0.01)
                first = read_frame()
                assert first["render"]["operationID"] == 1
                os.replace(root + "/render1.plist", root + "/prepared.plist")
                open(root + "/render1.read", "w").close()
                emit("render1.frame")
                second = read_frame()
                assert second["render"]["operationID"] == 3
                os.replace(root + "/render3.plist", root + "/prepared.plist")
                open(root + "/render3.read", "w").close()
                emit("render3.frame")
                third = read_frame()
                assert third["cancelVisualization"]["operationID"] == 2
                open(root + "/cancel2.read", "w").close()
                fourth = read_frame()
                assert fourth["visualize"]["operationID"] == 4
                open(root + "/visualize4.read", "w").close()
                emit("visualize4.frame")
                fifth = read_frame()
                if "cancelVisualization" in fifth:
                    fifth = read_frame()
                assert "shutdown" in fifth
                emit("shutdown.frame")
                """)
                return fixture
            }

            static func makeMalformedVisualization() throws -> Self {
                let fixture = try makeWorkspace(name: "MalformedVisualization")
                let address = LiveControlAddress(
                    revision: 23, target: .source(0), parameter: .gain)
                let catalog = try LiveControlCatalog(descriptors: [.init(
                    address: address, label: "Gain", baseline: .scalar(1)
                )])
                let loop = PreparedLoop(
                    sampleRate: 44_100, bpm: 120, beatsPerBar: 4, beatCount: 4,
                    samples: [Float](repeating: 0, count: 176_400), events: [])
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                try encoder.encode(WorkerPreparedResult(
                    revision: 23, generation: 0, loop: loop
                )).write(to: fixture.workspace.appending(path: "prepared.plist"))
                try RenderWorkerFraming.encode(
                    RenderWorkerResponse.ready(revision: 23, catalog: catalog)
                ).write(to: fixture.workspace.appending(path: "ready.frame"))
                try makeMalformedVisualizationFrame(
                    revision: 23, address: address
                ).write(to: fixture.workspace.appending(path: "malformed.frame"))
                try fixture.writeScript("""
                #!/usr/bin/env python3
                import os, sys, struct, plistlib
                root = \(pythonLiteral(fixture.workspace.path))
                \(fixture.pidWrite)
                def read_frame():
                    header = sys.stdin.buffer.read(4)
                    if len(header) != 4: sys.exit(1)
                    size = struct.unpack(">I", header)[0]
                    payload = sys.stdin.buffer.read(size)
                    if len(payload) != size: sys.exit(1)
                    return plistlib.loads(payload)
                emit = lambda name: (sys.stdout.buffer.write(open(root + "/" + name, "rb").read()), sys.stdout.buffer.flush())
                emit("ready.frame")
                command = read_frame()
                assert command["visualize"]["operationID"] == 1
                emit("malformed.frame")
                """)
                return fixture
            }

            static func makeQueuedCancellation() throws -> Self {
                let fixture = try makeWorkspace(name: "VisualizationCancellation")
                let address = LiveControlAddress(
                    revision: 24, target: .source(0), parameter: .gain)
                let catalog = try LiveControlCatalog(descriptors: [.init(
                    address: address, label: "Gain", baseline: .scalar(1)
                )])
                let loop = PreparedLoop(
                    sampleRate: 44_100, bpm: 120, beatsPerBar: 4, beatCount: 4,
                    samples: [Float](repeating: 0, count: 176_400), events: [])
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                try encoder.encode(WorkerPreparedResult(
                    revision: 24, generation: 0, loop: loop
                )).write(to: fixture.workspace.appending(path: "prepared.plist"))
                try RenderWorkerFraming.encode(
                    RenderWorkerResponse.ready(revision: 24, catalog: catalog)
                ).write(to: fixture.workspace.appending(path: "ready.frame"))
                try makeVisualizationFrame(
                    revision: 24, operationID: 2, selectionGeneration: 2, address: address
                ).write(to: fixture.workspace.appending(path: "visualize2.frame"))
                try RenderWorkerFraming.encode(RenderWorkerResponse.shutdownComplete)
                    .write(to: fixture.workspace.appending(path: "shutdown.frame"))
                try fixture.writeScript("""
                #!/usr/bin/env python3
                import os, sys, struct, plistlib
                root = \(pythonLiteral(fixture.workspace.path))
                \(fixture.pidWrite)
                def read_frame():
                    header = sys.stdin.buffer.read(4)
                    if len(header) != 4: sys.exit(1)
                    size = struct.unpack(">I", header)[0]
                    payload = sys.stdin.buffer.read(size)
                    if len(payload) != size: sys.exit(1)
                    return plistlib.loads(payload)
                def emit(name):
                    sys.stdout.buffer.write(open(root + "/" + name, "rb").read())
                    sys.stdout.buffer.flush()
                emit("ready.frame")
                first = read_frame()
                assert first["visualize"]["operationID"] == 1
                open(root + "/visualize1.received", "w").close()
                cancel = read_frame()
                assert cancel["cancelVisualization"]["operationID"] == 1
                open(root + "/cancel1.received", "w").close()
                second = read_frame()
                assert second["visualize"]["operationID"] == 2
                emit("visualize2.frame")
                shutdown = read_frame()
                assert "shutdown" in shutdown
                emit("shutdown.frame")
                """)
                return fixture
            }

            private static func makeWorkspace(name: String) throws -> Self {
                let workspace = FileManager.default.temporaryDirectory
                    .appending(path: "P073-\(name)-\(UUID().uuidString)")
                try FileManager.default.createDirectory(
                    at: workspace, withIntermediateDirectories: true)
                let executable = workspace.appending(path: "worker.py")
                let pidFile = workspace.appending(path: "pid")
                return Self(workspace: workspace, executable: executable, pidFile: pidFile)
            }

            private var pidWrite: String {
                "temp = \(Self.pythonLiteral(pidFile.path + ".tmp")); " +
                "open(temp, \"w\").write(str(os.getpid())); " +
                "os.replace(temp, \(Self.pythonLiteral(pidFile.path)))"
            }

            private func writeScript(_ script: String) throws {
                try Data(script.utf8).write(to: executable)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: executable.path)
            }

            func pid() async throws -> Int32 {
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while ContinuousClock.now < deadline {
                    if FileManager.default.fileExists(atPath: pidFile.path) {
                        let text = try String(contentsOf: pidFile, encoding: .utf8)
                        if let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            return pid
                        }
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                throw EvaluationError.timedOut("Visualization fixture did not publish its PID.")
            }

            func touch(_ name: String) throws {
                try Data().write(to: workspace.appending(path: name))
            }

            func waitForMarker(_ name: String) async throws {
                let marker = workspace.appending(path: name)
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while ContinuousClock.now < deadline {
                    if FileManager.default.fileExists(atPath: marker.path) { return }
                    try await Task.sleep(for: .milliseconds(20))
                }
                throw EvaluationError.timedOut("Visualization fixture did not receive \(name).")
            }

            func waitUntilGone(_ pid: Int32) async throws {
                guard Darwin.kill(pid, 0) == -1, errno == ESRCH else {
                    throw EvaluationError.processFailed("Visualization fixture was not reaped.")
                }
            }

            func remove() throws {
                try FileManager.default.removeItem(at: workspace)
            }

            private static func pythonLiteral(_ path: String) -> String {
                "'" + path.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'") + "'"
            }
        }

        private static func makeVisualizationFrame(
            revision: UInt64,
            operationID: UInt64,
            selectionGeneration: UInt64,
            address: LiveControlAddress
        ) throws -> Data {
            let channel = PreparedControlTrace.Channel(
                kind: .selectedValue,
                points: [.init(beat: 0, value: 0.5), .init(beat: 4, value: 0.5)]
            )
            let trace = PreparedControlTrace(
                eventIndex: 0, sourceID: 0, startBeat: 0, durationBeats: 4,
                wrapsLoopBoundary: false, channels: [channel]
            )
            let visualization = try PreparedControlVisualization(
                address: address, unit: .amplitude, beatCount: 4, traces: [trace])
            return try RenderWorkerFraming.encode(RenderWorkerResponse.visualized(
                revision: revision,
                selectionGeneration: selectionGeneration,
                operationID: operationID,
                visualization: visualization
            ))
        }

        private static func makeMalformedVisualizationFrame(
            revision: UInt64,
            address: LiveControlAddress
        ) throws -> Data {
            let valid = try makeVisualizationFrame(
                revision: revision, operationID: 1, selectionGeneration: 1, address: address)
            let payload = Data(valid.dropFirst(RenderWorkerFraming.headerByteCount))
            let propertyList = try PropertyListSerialization.propertyList(
                from: payload, options: [], format: nil)

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

            let malformed = try PropertyListSerialization.data(
                fromPropertyList: corrupt(propertyList), format: .binary, options: 0)
            var frame = Data()
            let length = UInt32(malformed.count)
            frame.append(UInt8((length >> 24) & 0xff))
            frame.append(UInt8((length >> 16) & 0xff))
            frame.append(UInt8((length >> 8) & 0xff))
            frame.append(UInt8(length & 0xff))
            frame.append(malformed)
            return frame
        }
    }
}
