import Darwin
import Foundation

/// Evaluates trusted local Swift in a cancellable child process, outside the audio path.
public actor SourceEvaluator {
    private let packageURL: URL
    private let workspace: URL
    private let swiftExecutable: String
    private var busy = false
    private struct Worker {
        let revision: UInt64
        let connection: RenderWorkerConnection
        let directory: URL
        let resultLines: [Int: Int]
    }
    private var adopted: Worker?
    private var candidate: Worker?
    private var exportingWorker: Worker?
    private var retiredExportWorker: Worker?


    public init(packageURL: URL, workspace: URL, swiftExecutable: String) {
        self.packageURL = packageURL
        self.workspace = workspace
        self.swiftExecutable = swiftExecutable
    }

    internal func workerStateForTests() async -> (pid: pid_t?, exporting: UInt64?, retired: UInt64?) {
        let worker = adopted
        let exporting = exportingWorker?.revision
        let retired = retiredExportWorker?.revision
        return (await worker?.connection.processIdentifierForTests, exporting, retired)
    }

    public func evaluate(source: String, bpm: Double, beatsPerBar: Int) async throws -> PreparedLoop {
        let result = try await evaluateRetained(source: source, bpm: bpm, beatsPerBar: beatsPerBar, revision: 0)
        await discard(revision: 0)
        return result.loop
    }

    public func evaluateRetained(source: String, bpm: Double, beatsPerBar: Int,
                                 revision: UInt64) async throws -> RetainedEvaluation {
        // An actor may reenter at every await. This slot also protects the incremental workspace.
        while busy {
            try await Task.sleep(for: .milliseconds(40))
        }
        try Task.checkCancellation()
        busy = true
        defer { busy = false }
        if let previous = candidate {
            candidate = nil
            await previous.connection.shutdown()
            try FileManager.default.removeItem(at: previous.directory)
        }
        guard source.utf8.count <= 65_536 else {
            throw EvaluationError.invalidSource("Source exceeds the 64 KiB editor limit.")
        }
        guard bpm.isFinite, (40...240).contains(bpm), (2...7).contains(beatsPerBar) else {
            throw EvaluationError.invalidSource("Tempo must be 40–240 BPM and meter 2/4–7/4.")
        }
        let manager = FileManager.default
        let workerDirectory = workspace.appending(path: "Worker-" + UUID().uuidString)
        let sources = workspace.appending(path: "Sources/Evaluation")
        try manager.createDirectory(at: sources, withIntermediateDirectories: true)
        let manifest = """
        // swift-tools-version: 6.4
        import PackageDescription
        let package = Package(
            name: "MusicPlaygourndEvaluation",
            platforms: [.macOS(.v15)],
            dependencies: [
                .package(path: \(Self.swiftLiteral(packageURL.deletingLastPathComponent().path))),
                .package(path: \(Self.swiftLiteral(packageURL.path)))
            ],
            targets: [.executableTarget(name: "Evaluation", dependencies: [
                .product(name: "MusicPlaygourndCore", package: "MusicPlaygournd"),
                .product(name: "SwiftMusic", package: "SwiftMusic")
            ])]
        )
        """
        let manifestURL = workspace.appending(path: "Package.swift")
        if try !manager.fileExists(atPath: manifestURL.path) || String(contentsOf: manifestURL, encoding: .utf8) != manifest {
            try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        }
        let output = workerDirectory.appending(path: "prepared.plist")
        if manager.fileExists(atPath: output.path) { try manager.removeItem(at: output) }
        let maximumLiveBeats = Int(min(
            PreparedLoop.maximumBeatCount,
            (PreparedLoop.maximumDurationSeconds * bpm / 60).rounded(.down)
        ))
        let wrapper = """
        import Foundation
        import SwiftMusic
        import MusicPlaygourndCore
        #sourceLocation(file: "Session.swift", line: 1)
        \(source)
        #sourceLocation()
        @main
        struct EvaluationEntry {
            static func main() async {
              do {
                let bounds = try SoundCompiler.Limits(maximumEvents: 1024, maximumSources: 32, maximumRenderNodes: 256, maximumBuses: 32)
                let policy = try LiveLoopPolicy(
                    beatsPerBar: \(beatsPerBar),
                    maximumBeats: MusicalTime(numerator: \(maximumLiveBeats), denominator: 1)
                )
                try await RenderWorker.run(revision: \(revision), outputURL: URL(fileURLWithPath: \(Self.swiftLiteral(output.path)))) {
                    let sound = try SoundCompiler(limits: bounds).compile(Session(), liveLoop: policy)
                    return try LoopRenderSession(sound: sound, bpm: \(bpm), beatsPerBar: \(beatsPerBar), revision: \(revision))
                }
              } catch {
                FileHandle.standardError.write(Data("Music preparation error: \\(String(describing: error))\\n".utf8))
                exit(1)
              }
            }
        }
        """
        try wrapper.write(to: sources.appending(path: "Session.swift"), atomically: true, encoding: .utf8)
        _ = try await run(swiftExecutable, ["build", "--build-system", "native", "-Xswiftc", "-Xfrontend", "-Xswiftc", "-disable-round-trip-debug-types", "--package-path", workspace.path, "--product", "Evaluation"], timeout: 120)
        let binaryOutput = try await run(swiftExecutable, ["build", "--build-system", "native", "--package-path", workspace.path, "--show-bin-path"], timeout: 20)
        let binaryPaths = binaryOutput.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("/") }
        guard binaryPaths.count == 1, let path = binaryPaths.first else {
            throw EvaluationError.invalidResult("SwiftPM did not report one absolute binary directory.")
        }
        let binaryPath = String(path)
        try manager.createDirectory(at: workerDirectory, withIntermediateDirectories: true)
        let connection = try RenderWorkerConnection(
            executable: URL(fileURLWithPath: binaryPath).appending(path: "Evaluation"),
            outputURL: output, revision: revision)
        do {
        let initial = try await connection.ready()
        let loop = initial.loop
        let prefix = "import Foundation\nimport SwiftMusic\nimport MusicPlaygourndCore\n"
        let displaySource = workspace.appending(path: "ResultLocations.swift")
        try (prefix + source).write(to: displaySource, atomically: true, encoding: .utf8)
        let sdk = try await run("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"], timeout: 20)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        guard sdk.hasPrefix("/"), manager.fileExists(atPath: sdk, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EvaluationError.invalidResult("The active macOS SDK is not an existing absolute directory.")
        }
        let ast = try await run(swiftExecutable, ["-frontend", "-dump-ast", "-dump-ast-format", "json", "-suppress-warnings",
            "-sdk", sdk,
            "-I", binaryPath, "-I", URL(fileURLWithPath: binaryPath).appending(path: "Modules").path,
            displaySource.path], timeout: 20)
        let resultLines = try ExpressionResultLocations.lines(ast: Data(ast.utf8), source: source, prefixBytes: prefix.utf8.count, rows: loop.rows)
        let located = PreparedLoop(sampleRate: loop.sampleRate, bpm: loop.bpm, beatsPerBar: loop.beatsPerBar,
            beatCount: loop.beatCount, samples: loop.samples, events: loop.events,
            rows: loop.rows.map { row in
                LoopRow(sourceID: row.sourceID, label: row.label, anchor: row.anchor, peaks: row.peaks,
                    patternText: row.patternText, resultLine: resultLines[row.sourceID])
            })
        try located.validate()
        try Task.checkCancellation()
        candidate = Worker(revision: revision, connection: connection,
                           directory: workerDirectory, resultLines: resultLines)
        return RetainedEvaluation(loop: located, catalog: initial.catalog)
        } catch {
            await connection.shutdown()
            try manager.removeItem(at: workerDirectory)
            throw error
        }
    }

    @discardableResult public func adopt(revision: UInt64) async -> Bool {
        if let adopted, adopted.revision == revision { return await adopted.connection.isAvailable }
        guard let next = candidate, next.revision == revision,
              await next.connection.isAvailable else { return false }
        guard candidate?.revision == revision else { return false }
        let previous = adopted
        adopted = next
        candidate = nil
        if let previous {
            if exportingWorker?.revision == previous.revision {
                retiredExportWorker = previous
            } else {
                await previous.connection.shutdown()
                do { try FileManager.default.removeItem(at: previous.directory) }
                catch { /* Workspace cleanup is retried by shutdown. */ }
            }
        }
        return await controlsAvailable(revision: revision)
    }

    public func controlsAvailable(revision: UInt64) async -> Bool {
        guard let worker = adopted, worker.revision == revision else { return false }
        let available = await worker.connection.isAvailable
        return available && adopted?.revision == revision
    }

    public func discard(revision: UInt64) async {
        guard let value = candidate, value.revision == revision else { return }
        candidate = nil
        await value.connection.shutdown()
        do { try FileManager.default.removeItem(at: value.directory) }
        catch { /* Workspace cleanup is retried by shutdown. */ }
    }

    public func render(overrides: [LiveControlOverride], revision: UInt64,
                       generation: UInt64) async throws -> PreparedLoop {
        guard let worker = adopted, worker.revision == revision else {
            throw EvaluationError.invalidResult("Control revision is not adopted.")
        }
        let loop = try await worker.connection.render(overrides: overrides, generation: generation)
        guard adopted?.revision == revision else { throw CancellationError() }
        let located = PreparedLoop(sampleRate: loop.sampleRate, bpm: loop.bpm,
            beatsPerBar: loop.beatsPerBar, beatCount: loop.beatCount, samples: loop.samples,
            events: loop.events, rows: loop.rows.map {
                LoopRow(sourceID: $0.sourceID, label: $0.label, anchor: $0.anchor, peaks: $0.peaks,
                        patternText: $0.patternText, resultLine: worker.resultLines[$0.sourceID])
            })
        try located.validate()
        return located
    }

    /// Exports the adopted retained session's Track stems without replacing its loop result.
    public func exportStems(
        revision: UInt64,
        generation: UInt64,
        overrides: [LiveControlOverride],
        destination: URL
    ) async throws -> StemExportSnapshot {
        guard destination.isFileURL, destination.path.hasPrefix("/"), destination.path != "/" else {
            throw StemExportError.invalidDestination
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw StemExportError.destinationExists
        }
        guard let worker = adopted, worker.revision == revision else {
            throw EvaluationError.invalidResult("Control revision is not adopted.")
        }
        guard exportingWorker == nil else {
            throw EvaluationError.invalidResult("A stem export is already in progress.")
        }
        exportingWorker = worker
        do {
            let snapshot = try await worker.connection.exportStems(
                overrides: overrides,
                generation: generation,
                destination: destination
            )
            guard snapshot.revision == revision, snapshot.generation == generation else {
                throw EvaluationError.invalidResult("Stem export snapshot identity does not match its request.")
            }
            await finishExport(worker)
            return snapshot
        } catch {
            await finishExport(worker)
            throw error
        }
    }

    private func finishExport(_ worker: Worker) async {
        guard exportingWorker?.revision == worker.revision else { return }
        exportingWorker = nil
        let remainsAdopted = adopted?.revision == worker.revision
        if retiredExportWorker?.revision == worker.revision {
            retiredExportWorker = nil
        }
        guard !remainsAdopted else { return }
        await worker.connection.shutdown()
        do { try FileManager.default.removeItem(at: worker.directory) }
        catch { /* Workspace cleanup is retried by shutdown. */ }
    }

    /// Call after cancelling the caller's evaluation task; waits for child cleanup before removing scratch data.
    public func shutdown() async throws {
        while busy { try await Task.sleep(for: .milliseconds(40)) }
        let allWorkers = [adopted, candidate, retiredExportWorker, exportingWorker].compactMap { $0 }
        var workers = [Worker]()
        for worker in allWorkers where !workers.contains(where: { $0.revision == worker.revision }) {
            workers.append(worker)
        }
        adopted = nil
        candidate = nil
        exportingWorker = nil
        retiredExportWorker = nil
        for worker in workers { await worker.connection.shutdown() }
        if FileManager.default.fileExists(atPath: workspace.path) {
            try FileManager.default.removeItem(at: workspace)
        }
    }

    private func run(_ executable: String, _ arguments: [String], timeout: Double) async throws -> String {
        try Task.checkCancellation()
        let log = workspace.appending(path: "process.log")
        try Data().write(to: log)
        let output = try FileHandle(forWritingTo: log)
        defer { do { try output.close() } catch { /* Closing an already-finished diagnostic file cannot alter playback. */ } }
        let process = Process()
        let completion = ProcessCompletion()
        process.terminationHandler = { @Sendable task in
            completion.finish(status: task.terminationStatus, exited: task.terminationReason == .exit)
        }
        // Start a process group so cancellation also terminates swiftc and evaluated child processes.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", Self.processRunner, executable] + arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        do {
            while completion.result == nil {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw EvaluationError.timedOut("Evaluation exceeded \(Int(timeout)) seconds. The previous loop is still available.")
                }
                let size = try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber
                guard (size?.intValue ?? 0) <= 1_048_576 else {
                    throw EvaluationError.processFailed("Compiler or session output exceeded 1 MiB.")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            let pid = process.processIdentifier
            kill(-pid, SIGKILL)
            if process.isRunning { kill(pid, SIGKILL) }
            // Cleanup must finish even when the evaluating Task is cancelled. Foundation's
            // termination handler reaps the child; waitUntilExit can deadlock across actor hops.
            let cleanup = Task.detached {
                while completion.result == nil { try await Task.sleep(for: .milliseconds(20)) }
            }
            try await cleanup.value
            throw error
        }
        // A session may start descendants; none should outlive evaluation.
        kill(-process.processIdentifier, SIGKILL)
        let data = try Data(contentsOf: log)
        guard data.count <= 1_048_576 else { throw EvaluationError.processFailed("Diagnostic output exceeded 1 MiB.") }
        let message = String(decoding: data, as: UTF8.self)
        guard let result = completion.result, result.exited, result.status == 0 else {
            throw EvaluationError.processFailed(message.isEmpty ? "The Swift process failed." : message)
        }
        try Task.checkCancellation()
        return message
    }

    // The pipe collector holds one 64 KiB chunk and writes at most 1 MiB to the log.
    // The group contains this launcher and its ordinary compiler/session descendants.
    private static let processRunner = """
    import os, signal, subprocess, sys
    if os.getpgrp() != os.getpid():
        os.setpgid(0, 0)
    child = subprocess.Popen(sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    limit = 1048576
    marker = b"\\nOutput exceeded the 1 MiB diagnostic limit.\\n"
    accepted = 0
    while True:
        chunk = child.stdout.read1(65536)
        if not chunk:
            break
        room = limit - len(marker) - accepted
        if len(chunk) > room:
            sys.stdout.buffer.write(chunk[:max(0, room)] + marker)
            sys.stdout.buffer.flush()
            os.killpg(os.getpid(), signal.SIGKILL)
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
        accepted += len(chunk)
    status = child.wait()
    sys.exit(status if status >= 0 else 128 - status)
    """

    private static func swiftLiteral(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
}
