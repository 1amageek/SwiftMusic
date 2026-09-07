import Darwin
import Foundation

/// Evaluates trusted local Swift in a cancellable child process, outside the audio path.
public actor SourceEvaluator {
    private let packageURL: URL
    private let workspace: URL
    private let swiftExecutable: String
    private var busy = false

    public init(packageURL: URL, workspace: URL, swiftExecutable: String) {
        self.packageURL = packageURL
        self.workspace = workspace
        self.swiftExecutable = swiftExecutable
    }

    public func evaluate(source: String, bpm: Double, beatsPerBar: Int) async throws -> PreparedLoop {
        guard source.utf8.count <= 65_536 else {
            throw EvaluationError.invalidSource("Source exceeds the 64 KiB editor limit.")
        }
        guard bpm.isFinite, (40...240).contains(bpm), (2...7).contains(beatsPerBar) else {
            throw EvaluationError.invalidSource("Tempo must be 40–240 BPM and meter 2/4–7/4.")
        }
        // An actor may reenter at every await. This slot also protects the incremental workspace.
        while busy {
            try await Task.sleep(for: .milliseconds(40))
        }
        try Task.checkCancellation()
        busy = true
        defer { busy = false }
        let manager = FileManager.default
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
        let output = workspace.appending(path: "prepared.plist")
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
            static func main() {
              do {
                let bounds = try SoundCompiler.Limits(maximumEvents: 1024, maximumSources: 32, maximumRenderNodes: 256, maximumBuses: 32)
                let policy = try LiveLoopPolicy(
                    beatsPerBar: \(beatsPerBar),
                    maximumBeats: MusicalTime(numerator: \(maximumLiveBeats), denominator: 1)
                )
                let sound = try SoundCompiler(limits: bounds).compile(Session(), liveLoop: policy)
                let loop = try LoopRenderer().render(sound, bpm: \(bpm), beatsPerBar: \(beatsPerBar))
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                try encoder.encode(loop).write(to: URL(fileURLWithPath: \(Self.swiftLiteral(output.path))), options: .atomic)
              } catch {
                FileHandle.standardError.write(Data("Music preparation error: \\(String(describing: error))\\n".utf8))
                exit(1)
              }
            }
        }
        """
        try wrapper.write(to: sources.appending(path: "Session.swift"), atomically: true, encoding: .utf8)
        _ = try await run(swiftExecutable, ["build", "--package-path", workspace.path, "--product", "Evaluation"], timeout: 120)
        let binaryPath = try await run(swiftExecutable, ["build", "--package-path", workspace.path, "--show-bin-path"], timeout: 20)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await run(URL(fileURLWithPath: binaryPath).appending(path: "Evaluation").path, [], timeout: 10)
        guard manager.fileExists(atPath: output.path) else {
            throw EvaluationError.invalidResult("The Swift session did not produce a prepared loop.")
        }
        let size = try manager.attributesOfItem(atPath: output.path)[.size] as? NSNumber
        guard let size, size.intValue <= 16 * 1024 * 1024 else {
            throw EvaluationError.invalidResult("Prepared output exceeds 16 MiB.")
        }
        let loop = try PropertyListDecoder().decode(PreparedLoop.self, from: Data(contentsOf: output))
        try loop.validate()
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
        return located
    }

    /// Call after cancelling the caller's evaluation task; waits for child cleanup before removing scratch data.
    public func shutdown() async throws {
        while busy { try await Task.sleep(for: .milliseconds(40)) }
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
