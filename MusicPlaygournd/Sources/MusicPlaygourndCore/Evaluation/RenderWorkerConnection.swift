import Darwin
import Foundation

/// Owns one child and bounded nonblocking pipes; the pump never blocks an actor executor.
internal actor RenderWorkerConnection {
    private let process: Process
    private let completion: ProcessCompletion
    private let input: FileHandle
    private let output: FileHandle
    private let errors: FileHandle
    private let outputURL: URL
    private let revision: UInt64
    private var parser = RenderWorkerFrameParser()
    private var diagnostic = Data()
    private var writing: Data?
    private var written = 0
    private var pendingWrite: Data?
    private var waiter: CheckedContinuation<WorkerPreparedResult, any Error>?
    private var readyWaiter: CheckedContinuation<RetainedEvaluation, any Error>?
    private var readyResult: RetainedEvaluation?
    private var failure: EvaluationError?
    private var latestGeneration: UInt64 = 0
    private var deadline: ContinuousClock.Instant?
    private var pumpTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var stopping = false
    private var closing = false

    init(executable: URL, outputURL: URL, revision: UInt64) throws {
        self.outputURL = outputURL
        self.revision = revision
        let process = Process()
        let completion = ProcessCompletion()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import os,sys; os.setpgid(0,0); os.execv(sys.argv[1], [sys.argv[1]])", executable.path]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { task in
            completion.finish(status: task.terminationStatus, exited: task.terminationReason == .exit)
        }
        self.process = process
        self.completion = completion
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        for handle in [input, output, errors] {
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw EvaluationError.processFailed("Unable to configure worker pipe.")
            }
        }
        // Prevent a worker exit during a write from terminating the editor process.
        guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) >= 0 else {
            throw EvaluationError.processFailed("Unable to protect worker pipe writes.")
        }
        try process.run()
    }

    var isAvailable: Bool { readyResult != nil && failure == nil && !stopping && !closing }

    func ready() async throws -> RetainedEvaluation {
        try Task.checkCancellation()
        if let readyResult { return readyResult }
        if let failure { throw failure }
        guard readyWaiter == nil else { throw EvaluationError.invalidResult("Worker initialization already awaited.") }
        deadline = .now.advanced(by: .seconds(10))
        pumpTask = Task { await self.pump() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { readyWaiter = $0 }
        } onCancel: {
            Task { await self.cancelInitialization() }
        }
    }

    func render(overrides: [LiveControlOverride], generation: UInt64) async throws -> PreparedLoop {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard readyResult != nil, !stopping, !closing else { throw EvaluationError.invalidResult("Worker is unavailable.") }
        guard generation > latestGeneration else { throw EvaluationError.invalidResult("Worker generation is stale.") }
        guard overrides.count <= (readyResult?.catalog.descriptors.count ?? 0) else {
            throw EvaluationError.invalidResult("Override count exceeds the worker control catalog.")
        }
        let frame = try RenderWorkerFraming.encode(RenderWorkerCommand.render(
            revision: revision, generation: generation, overrides: overrides))
        latestGeneration = generation
        waiter?.resume(throwing: CancellationError())
        waiter = nil
        // Finish a partially written frame, retaining only one subsequent request.
        if writing == nil { writing = frame; written = 0 }
        else { pendingWrite = frame }
        deadline = .now.advanced(by: .seconds(10))
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: {
            Task { await self.cancelWaiter(generation) }
        } as WorkerPreparedResult
        try Task.checkCancellation()
        return result.loop
    }

    private func cancelWaiter(_ generation: UInt64) {
        guard generation == latestGeneration else { return }
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }

    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        let task = Task { await self.closeWorker() }
        shutdownTask = task
        await task.value
    }

    private func closeWorker() async {
        closing = true
        if failure == nil, completion.result == nil {
            do {
                let command = try RenderWorkerFraming.encode(RenderWorkerCommand.shutdown)
                if writing == nil { writing = command; written = 0 }
                else { pendingWrite = command }
                let until = ContinuousClock.now.advanced(by: .seconds(10))
                while completion.result == nil, ContinuousClock.now < until, failure == nil {
                    try await Task.sleep(for: .milliseconds(10))
                }
            } catch {
                failure = .processFailed("Worker shutdown failed: \(error)")
            }
        }
        stopping = true
        waiter?.resume(throwing: CancellationError()); waiter = nil
        readyWaiter?.resume(throwing: CancellationError()); readyWaiter = nil
        // Reap the worker and any user-created descendants, including a hung shutdown.
        kill(-process.processIdentifier, SIGKILL)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        while completion.result == nil {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { continue }
        }
        pumpTask?.cancel()
        pumpTask = nil
        for handle in [input, output, errors] {
            do { try handle.close() }
            catch { failure = .processFailed("Worker pipe cleanup failed: \(error)") }
        }
    }

    private func abort(_ error: EvaluationError) async {
        failure = error
        waiter?.resume(throwing: error); waiter = nil
        readyWaiter?.resume(throwing: error); readyWaiter = nil
        await shutdown()
    }

    private func cancelInitialization() async {
        failure = .processFailed("Worker initialization cancelled.")
        readyWaiter?.resume(throwing: CancellationError()); readyWaiter = nil
        await shutdown()
    }

    private func pump() async {
        while !stopping {
            do {
                try readDiagnostics()
                try writeCommand()
                var bytes = [UInt8](repeating: 0, count: 16_384)
                let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
                if count > 0 {
                    for payload in try parser.append(Data(bytes.prefix(count))) {
                        try receive(RenderWorkerFraming.decode(RenderWorkerResponse.self, payload: payload))
                    }
                } else if count == 0 {
                    try parser.finish()
                    if closing { return }
                    throw EvaluationError.processFailed("Worker exited. \(String(decoding: diagnostic, as: UTF8.self))")
                } else if errno != EAGAIN && errno != EINTR {
                    throw EvaluationError.processFailed("Worker protocol read failed.")
                }
                if let deadline, ContinuousClock.now >= deadline {
                    throw EvaluationError.timedOut("Worker exceeded 10 seconds; the previous loop continues.")
                }
                try await Task.sleep(for: .milliseconds(10))
            } catch is CancellationError { return }
            catch let error as EvaluationError { await abort(error); return }
            catch { await abort(.processFailed(String(describing: error))); return }
        }
    }

    private func readDiagnostics() throws {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.read(errors.fileDescriptor, &bytes, bytes.count)
        if count > 0 {
            guard diagnostic.count + count <= 1_048_576 else {
                throw EvaluationError.processFailed("Worker exceeded the 1 MiB diagnostic limit.")
            }
            diagnostic.append(contentsOf: bytes.prefix(count))
        } else if count < 0, errno != EAGAIN && errno != EINTR {
            throw EvaluationError.processFailed("Worker diagnostic read failed.")
        }
    }

    private func writeCommand() throws {
        guard let writing else { return }
        let count = writing.withUnsafeBytes { bytes in
            Darwin.write(input.fileDescriptor, bytes.baseAddress!.advanced(by: written), writing.count - written)
        }
        if count > 0 {
            written += count
            if written == writing.count {
                self.writing = pendingWrite
                pendingWrite = nil
                written = 0
            }
        } else if count < 0, errno != EAGAIN && errno != EINTR {
            throw EvaluationError.processFailed("Worker command write failed.")
        }
    }

    private func receive(_ response: RenderWorkerResponse) throws {
        switch response {
        case .ready(let responseRevision, let catalog):
            guard responseRevision == revision, readyResult == nil,
                  catalog.descriptors.allSatisfy({ $0.address.revision == revision }) else {
                throw EvaluationError.invalidResult("Invalid worker ready response.")
            }
            let result = try readResult(generation: 0)
            let ready = RetainedEvaluation(loop: result.loop, catalog: catalog)
            readyResult = ready
            deadline = nil
            readyWaiter?.resume(returning: ready); readyWaiter = nil
        case .rendered(let responseRevision, let generation):
            guard responseRevision == revision, generation <= latestGeneration else {
                throw EvaluationError.invalidResult("Invalid worker render identity.")
            }
            guard generation == latestGeneration else { return }
            let result = try readResult(generation: generation)
            deadline = nil
            waiter?.resume(returning: result); waiter = nil
        case .failed(let responseRevision, let generation, let message):
            guard responseRevision == revision, generation <= latestGeneration else {
                throw EvaluationError.invalidResult("Invalid worker failure identity.")
            }
            guard generation == latestGeneration else { return }
            deadline = nil
            waiter?.resume(throwing: EvaluationError.processFailed(message)); waiter = nil
        case .shutdownComplete:
            guard closing else { throw EvaluationError.invalidResult("Unexpected worker shutdown.") }
            deadline = nil
        }
    }

    private func readResult(generation: UInt64) throws -> WorkerPreparedResult {
        let size = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber
        guard let size, size.intValue <= 16 * 1024 * 1024 else {
            throw EvaluationError.invalidResult("Worker result exceeds 16 MiB.")
        }
        let result = try PropertyListDecoder().decode(WorkerPreparedResult.self, from: Data(contentsOf: outputURL))
        guard result.revision == revision, result.generation == generation else {
            throw EvaluationError.invalidResult("Worker result identity does not match its response.")
        }
        try result.loop.validate()
        return result
    }
}
