import Darwin
import Foundation

/// Owns one child and bounded nonblocking pipes; the pump never blocks an actor executor.
internal actor RenderWorkerConnection {
    private enum WorkerOperationResult: Sendable {
        case loop(WorkerPreparedResult)
        case stems(StemExportSnapshot)
        case visualization(PreparedControlVisualization)
    }

    private enum CommandKind: Equatable {
        case render
        case export
        case cancelExport
        case visualize
        case cancelVisualization
        case shutdown
    }

    private struct PendingCommand {
        let kind: CommandKind
        let data: Data
    }

    internal var processIdentifierForTests: pid_t { process.processIdentifier }

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
    private var pendingWrites = [PendingCommand]()
    private var renderWaiter: CheckedContinuation<WorkerOperationResult, any Error>?
    private var exportWaiter: CheckedContinuation<WorkerOperationResult, any Error>?
    private var visualizationWaiter: CheckedContinuation<WorkerOperationResult, any Error>?
    private var readyWaiter: CheckedContinuation<RetainedEvaluation, any Error>?
    private var readyResult: RetainedEvaluation?
    private var failure: EvaluationError?
    private var latestRenderGeneration: UInt64 = 0
    private var lastRenderedGeneration: UInt64 = 0
    private var latestExportGeneration: UInt64 = 0
    private var latestVisualizationSelectionGeneration: UInt64 = 0
    private var nextOperationID: UInt64 = 0
    private var latestOperationID: UInt64 = 0
    private var latestRenderOperationID: UInt64 = 0
    private var latestExportOperationID: UInt64 = 0
    private var latestVisualizationOperationID: UInt64 = 0
    private var latestVisualizationAddress: LiveControlAddress?
    private var exportCancellationRequested = false
    private var readyDeadline: ContinuousClock.Instant?
    private var renderDeadline: ContinuousClock.Instant?
    private var exportDeadline: ContinuousClock.Instant?
    private var visualizationDeadline: ContinuousClock.Instant?
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
        readyDeadline = .now.advanced(by: .seconds(10))
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
        guard generation > latestRenderGeneration else { throw EvaluationError.invalidResult("Worker generation is stale.") }
        guard overrides.count <= (readyResult?.catalog.descriptors.count ?? 0) else {
            throw EvaluationError.invalidResult("Override count exceeds the worker control catalog.")
        }
        let operationID = try allocateOperationID()
        latestRenderOperationID = operationID
        let frame = try RenderWorkerFraming.encode(RenderWorkerCommand.render(
            revision: revision, generation: generation, operationID: operationID, overrides: overrides))
        latestRenderGeneration = generation
        renderWaiter?.resume(throwing: CancellationError())
        renderWaiter = nil
        renderDeadline = .now.advanced(by: .seconds(10))
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<WorkerOperationResult, any Error>) in
                renderWaiter = continuation
                enqueue(.render, frame)
            }
        } onCancel: {
            Task { await self.cancelRenderWaiter(operationID) }
        } as WorkerOperationResult
        try Task.checkCancellation()
        guard case .loop(let prepared) = result else {
            throw EvaluationError.invalidResult("Worker returned a stem export for a render request.")
        }
        return prepared.loop
    }

    func exportStems(
        overrides: [LiveControlOverride],
        generation: UInt64,
        destination: URL
    ) async throws -> StemExportSnapshot {
        try Task.checkCancellation()
        guard destination.isFileURL, destination.path.hasPrefix("/") else {
            throw StemExportError.invalidDestination
        }
        if let failure { throw failure }
        guard readyResult != nil, !stopping, !closing else { throw EvaluationError.invalidResult("Worker is unavailable.") }
        guard generation <= lastRenderedGeneration else {
            throw EvaluationError.invalidResult("Worker generation has not produced a retained render.")
        }
        guard overrides.count <= (readyResult?.catalog.descriptors.count ?? 0) else {
            throw EvaluationError.invalidResult("Override count exceeds the worker control catalog.")
        }
        let operationID = try allocateOperationID()
        latestExportOperationID = operationID
        let frame = try RenderWorkerFraming.encode(RenderWorkerCommand.exportStems(
            revision: revision, generation: generation, operationID: operationID,
            overrides: overrides, destination: destination))
        latestExportGeneration = generation
        exportWaiter?.resume(throwing: CancellationError())
        exportWaiter = nil
        exportCancellationRequested = false
        exportDeadline = .now.advanced(by: .seconds(10))
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<WorkerOperationResult, any Error>) in
                exportWaiter = continuation
                enqueue(.export, frame)
            }
        } onCancel: {
            Task { await self.cancelExportWaiter(operationID) }
        } as WorkerOperationResult
        guard case .stems(let snapshot) = result else {
            throw EvaluationError.invalidResult("Worker returned a render result for a stem export request.")
        }
        return snapshot
    }

    func visualization(
        address: LiveControlAddress,
        overrides: [LiveControlOverride],
        selectionGeneration: UInt64
    ) async throws -> PreparedControlVisualization {
        try Task.checkCancellation()
        guard address.revision == revision else {
            throw LiveControlError.staleRevision(expected: revision, actual: address.revision)
        }
        if let failure { throw failure }
        guard readyResult != nil, !stopping, !closing else {
            throw EvaluationError.invalidResult("Worker is unavailable.")
        }
        guard selectionGeneration > latestVisualizationSelectionGeneration else {
            throw EvaluationError.invalidResult("Visualization selection generation is stale.")
        }
        guard overrides.count <= (readyResult?.catalog.descriptors.count ?? 0) else {
            throw EvaluationError.invalidResult("Override count exceeds the worker control catalog.")
        }
        let operationID = try allocateOperationID()
        if let waiter = visualizationWaiter {
            visualizationWaiter = nil
            visualizationDeadline = nil
            waiter.resume(throwing: CancellationError())
            try enqueueVisualizationCancellation(operationID: latestVisualizationOperationID)
        }
        latestVisualizationOperationID = operationID
        latestVisualizationSelectionGeneration = selectionGeneration
        latestVisualizationAddress = address
        let frame = try RenderWorkerFraming.encode(RenderWorkerCommand.visualize(
            revision: revision,
            selectionGeneration: selectionGeneration,
            operationID: operationID,
            address: address,
            overrides: overrides
        ))
        visualizationDeadline = .now.advanced(by: .seconds(10))
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<WorkerOperationResult, any Error>) in
                visualizationWaiter = continuation
                enqueue(.visualize, frame)
            }
        } onCancel: {
            Task { await self.cancelVisualizationWaiter(operationID) }
        } as WorkerOperationResult
        try Task.checkCancellation()
        guard case .visualization(let value) = result else {
            throw EvaluationError.invalidResult("Worker returned a non-visualization result.")
        }
        return value
    }

    private func cancelRenderWaiter(_ operationID: UInt64) {
        guard operationID == latestRenderOperationID else { return }
        renderWaiter?.resume(throwing: CancellationError())
        renderWaiter = nil
    }

    private func cancelVisualizationWaiter(_ operationID: UInt64) {
        guard operationID == latestVisualizationOperationID else { return }
        visualizationDeadline = nil
        visualizationWaiter?.resume(throwing: CancellationError())
        visualizationWaiter = nil
        do {
            try enqueueVisualizationCancellation(operationID: operationID)
        } catch {
            failure = .processFailed("Unable to cancel visualization: \(error.localizedDescription)")
        }
    }

    private func enqueueVisualizationCancellation(operationID: UInt64) throws {
        guard operationID > 0 else { return }
        let frame = try RenderWorkerFraming.encode(RenderWorkerCommand.cancelVisualization(operationID: operationID))
        enqueue(.cancelVisualization, frame)
    }

    private func cancelExportWaiter(_ operationID: UInt64) {
        guard operationID == latestExportOperationID else { return }
        // The worker may already have crossed the atomic directory rename. Keep
        // the continuation alive until its terminal response identifies whether
        // the committed snapshot won the cancellation race.
        guard !exportCancellationRequested else { return }
        exportCancellationRequested = true
        do {
            let frame = try RenderWorkerFraming.encode(RenderWorkerCommand.cancelExport(operationID: operationID))
            enqueue(.cancelExport, frame)
        } catch {
            exportDeadline = nil
            let waiter = exportWaiter
            exportWaiter = nil
            waiter?.resume(throwing: error)
        }
    }

    private func enqueue(_ kind: CommandKind, _ data: Data) {
        if writing == nil {
            writing = data
            written = 0
            return
        }
        // Coalescing replaces the old request at the tail so unrelated commands
        // retain their chronological wire order.
        pendingWrites.removeAll { $0.kind == kind }
        pendingWrites.append(PendingCommand(kind: kind, data: data))
    }

    private func allocateOperationID() throws -> UInt64 {
        guard nextOperationID < UInt64.max else {
            throw EvaluationError.invalidResult("Worker operation ID limit reached.")
        }
        nextOperationID += 1
        latestOperationID = nextOperationID
        return nextOperationID
    }

    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        let task = Task { await self.closeWorker() }
        shutdownTask = task
        await task.value
    }

    private func closeWorker() async {
        closing = true
        renderWaiter?.resume(throwing: CancellationError()); renderWaiter = nil
        visualizationWaiter?.resume(throwing: CancellationError()); visualizationWaiter = nil
        readyWaiter?.resume(throwing: CancellationError()); readyWaiter = nil
        if failure == nil, completion.result == nil {
            do {
                if exportWaiter != nil, !exportCancellationRequested {
                    exportCancellationRequested = true
                    let cancel = try RenderWorkerFraming.encode(
                        RenderWorkerCommand.cancelExport(operationID: latestExportOperationID)
                    )
                    enqueue(.cancelExport, cancel)
                }
                if latestVisualizationOperationID > 0 {
                    try enqueueVisualizationCancellation(operationID: latestVisualizationOperationID)
                }
                let command = try RenderWorkerFraming.encode(RenderWorkerCommand.shutdown)
                enqueue(.shutdown, command)
                let until = ContinuousClock.now.advanced(by: .seconds(10))
                while completion.result == nil, ContinuousClock.now < until, failure == nil {
                    try await Task.sleep(for: .milliseconds(10))
                }
            } catch {
                failure = .processFailed("Worker shutdown failed: \(error)")
            }
        }
        stopping = true
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
        renderWaiter?.resume(throwing: error); renderWaiter = nil
        exportWaiter?.resume(throwing: error); exportWaiter = nil
        visualizationWaiter?.resume(throwing: error); visualizationWaiter = nil
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
                    if let compilerDiagnostic = WorkerCompilerDiagnostic.decode(from: diagnostic) {
                        throw EvaluationError.workerCompilerDiagnostic(compilerDiagnostic)
                    }
                    throw EvaluationError.processFailed("Worker exited. \(String(decoding: diagnostic, as: UTF8.self))")
                } else if errno != EAGAIN && errno != EINTR {
                    throw EvaluationError.processFailed("Worker protocol read failed.")
                }
                let deadlines = [readyDeadline, renderDeadline, exportDeadline, visualizationDeadline].compactMap { $0 }
                if let deadline = deadlines.min(), ContinuousClock.now >= deadline {
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
                if let next = pendingWrites.first {
                    pendingWrites.removeFirst()
                    self.writing = next.data
                } else {
                    self.writing = nil
                }
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
            let metadata: EditorSemanticMetadata
            if let stored = result.metadata {
                metadata = stored
            } else {
                do {
                    metadata = try EditorSemanticMetadata(revision: revision)
                } catch {
                    throw EvaluationError.invalidResult("Worker semantic metadata is invalid: \(error.localizedDescription)")
                }
            }
            let ready = RetainedEvaluation(loop: result.loop, catalog: catalog, metadata: metadata)
            readyResult = ready
            lastRenderedGeneration = 0
            readyDeadline = nil
            readyWaiter?.resume(returning: ready); readyWaiter = nil
        case .rendered(let responseRevision, let generation, let operationID):
            guard responseRevision == revision, operationID <= latestOperationID else {
                throw EvaluationError.invalidResult("Invalid worker render identity.")
            }
            guard operationID == latestRenderOperationID else { return }
            guard generation == latestRenderGeneration else {
                throw EvaluationError.invalidResult("Invalid worker render generation.")
            }
            guard let waiter = renderWaiter else { return }
            let result = try readResult(generation: generation)
            lastRenderedGeneration = generation
            renderDeadline = nil
            renderWaiter = nil
            waiter.resume(returning: .loop(result))
        case .stemsExported(let snapshot, let operationID):
            guard snapshot.revision == revision, operationID <= latestOperationID else {
                throw EvaluationError.invalidResult("Invalid worker stem export identity.")
            }
            guard operationID == latestExportOperationID else { return }
            guard snapshot.generation == latestExportGeneration else {
                throw EvaluationError.invalidResult("Invalid worker stem export generation.")
            }
            try validate(snapshot.manifest)
            exportDeadline = nil
            let waiter = exportWaiter
            exportWaiter = nil
            exportCancellationRequested = false
            waiter?.resume(returning: .stems(snapshot))
        case .visualized(let responseRevision, let selectionGeneration, let operationID, let visualization):
            guard responseRevision == revision, operationID <= latestOperationID else {
                throw EvaluationError.invalidResult("Invalid worker visualization identity.")
            }
            guard operationID == latestVisualizationOperationID else { return }
            guard selectionGeneration == latestVisualizationSelectionGeneration,
                  visualization.address == latestVisualizationAddress else {
                throw EvaluationError.invalidResult("Invalid worker visualization selection.")
            }
            guard let waiter = visualizationWaiter else { return }
            visualizationDeadline = nil
            visualizationWaiter = nil
            waiter.resume(returning: .visualization(visualization))
        case .visualizationFailed(let responseRevision, let selectionGeneration, let operationID, let failure):
            guard responseRevision == revision, operationID <= latestOperationID else {
                throw EvaluationError.invalidResult("Invalid worker visualization failure identity.")
            }
            guard operationID == latestVisualizationOperationID else { return }
            guard selectionGeneration == latestVisualizationSelectionGeneration else {
                throw EvaluationError.invalidResult("Invalid worker visualization failure selection.")
            }
            guard let waiter = visualizationWaiter else { return }
            visualizationDeadline = nil
            visualizationWaiter = nil
            waiter.resume(throwing: Self.visualizationError(failure))
        case .failed(let responseRevision, _, let operationID, let message):
            guard responseRevision == revision, operationID <= latestOperationID else {
                throw EvaluationError.invalidResult("Invalid worker failure identity.")
            }
            if operationID == latestRenderOperationID {
                renderDeadline = nil
                renderWaiter?.resume(throwing: EvaluationError.processFailed(message)); renderWaiter = nil
            } else if operationID == latestExportOperationID {
                exportDeadline = nil
                let waiter = exportWaiter
                exportWaiter = nil
                let wasCancelled = exportCancellationRequested
                exportCancellationRequested = false
                if wasCancelled {
                    waiter?.resume(throwing: CancellationError())
                } else {
                    waiter?.resume(throwing: EvaluationError.processFailed(message))
                }
            } else {
                return
            }
        case .shutdownComplete:
            guard closing else { throw EvaluationError.invalidResult("Unexpected worker shutdown.") }
            readyDeadline = nil
            renderDeadline = nil
            exportDeadline = nil
        }
    }

    private static func visualizationError(_ failure: RenderWorkerVisualizationFailure) -> any Error {
        switch failure {
        case .staleRevision(let expected, let actual):
            LiveControlError.staleRevision(expected: expected, actual: actual)
        case .unknownAddress(let address):
            LiveControlError.unknownAddress(address)
        case .unsupported(let address):
            ControlVisualizationError.unsupported(address)
        case .invalidValue(let address):
            LiveControlError.invalidValue(address)
        case .invalidData:
            ControlVisualizationError.invalidData
        case .pointLimit:
            ControlVisualizationError.pointLimit
        case .cancelled:
            CancellationError()
        case .failed(let message):
            EvaluationError.processFailed(message)
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
        if let metadata = result.metadata {
            guard metadata.revision == revision else {
                throw EvaluationError.invalidResult("Worker semantic metadata revision does not match its result.")
            }
        }
        try result.loop.validate()
        return result
    }

    private func validate(_ manifest: [StemExportManifest]) throws {
        guard manifest.count <= StemExporter.maximumStemCount else {
            throw EvaluationError.invalidResult("Worker returned too many stem files.")
        }
        var trackIDs = Set<Int>()
        var reference: StemExportManifest?
        for stem in manifest {
            guard stem.trackID >= 0, trackIDs.insert(stem.trackID).inserted,
                  !stem.label.isEmpty, !stem.fileName.isEmpty,
                  stem.fileName == URL(fileURLWithPath: stem.fileName).lastPathComponent,
                  !stem.fileName.contains("/"), !stem.fileName.contains("\\"),
                  stem.sampleRate == PreparedLoop.requiredSampleRate,
                  stem.bpm.isFinite, (40...240).contains(stem.bpm),
                  (2...7).contains(stem.beatsPerBar),
                  stem.beatCount.isFinite, stem.beatCount > 0,
                  stem.beatCount <= PreparedLoop.maximumBeatCount,
                  stem.frameCount > 0 else {
                throw EvaluationError.invalidResult("Worker returned invalid stem metadata.")
            }
            let duration = stem.beatCount * 60 / stem.bpm
            guard duration.isFinite, duration <= PreparedLoop.maximumDurationSeconds else {
                throw EvaluationError.invalidResult("Worker returned an out-of-bounds stem duration.")
            }
            let expectedFrameCount = Int((duration * PreparedLoop.requiredSampleRate).rounded(.up))
            guard expectedFrameCount == stem.frameCount else {
                throw EvaluationError.invalidResult("Worker returned a stem frame count inconsistent with its metadata.")
            }
            if let reference {
                guard stem.sampleRate == reference.sampleRate,
                      stem.bpm == reference.bpm,
                      stem.beatsPerBar == reference.beatsPerBar,
                      stem.beatCount == reference.beatCount,
                      stem.frameCount == reference.frameCount else {
                    throw EvaluationError.invalidResult("Worker returned unsynchronized stem metadata.")
                }
            } else {
                reference = stem
            }
        }
    }
}
