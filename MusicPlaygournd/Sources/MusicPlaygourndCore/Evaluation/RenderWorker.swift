import Darwin
import Foundation

/// The retained child-process entry point.
///
/// `compile` is invoked exactly once, after protocol output has been isolated
/// from user stdout. The returned session and its decoded samples remain in
/// this process for every subsequent generation.
public enum RenderWorker {
    public static let maximumResultBytes = 16 * 1024 * 1024

    public static func run(
        revision: UInt64,
        outputURL: URL,
        compile: @escaping @Sendable () throws -> LoopRenderSession
    ) async throws {
        let protocolDescriptor = try isolateProtocolOutput()
        defer { Darwin.close(protocolDescriptor) }

        let session = try compile()
        guard session.revision == revision else {
            throw EvaluationError.invalidResult("Compiled worker revision does not match the requested revision.")
        }
        let writer = RenderWorkerOutputWriter(fileDescriptor: protocolDescriptor)
        try publish(session.baseline, revision: revision, generation: 0, to: outputURL)
        try await writer.send(.ready(revision: revision, catalog: session.catalog))

        let state = RenderWorkerState(session: session, revision: revision, outputURL: outputURL, writer: writer)
        while true {
            let command = try RenderWorkerFraming.decode(
                RenderWorkerCommand.self,
                payload: try readFramePayload(from: STDIN_FILENO)
            )
            switch command {
            case .render(let commandRevision, let generation, let operationID, let overrides):
                try await state.submit(revision: commandRevision, generation: generation,
                                       operationID: operationID, overrides: overrides)
            case .exportStems(let commandRevision, let generation, let operationID, let overrides, let destination):
                try await state.submitExport(revision: commandRevision, generation: generation,
                                             operationID: operationID, overrides: overrides, destination: destination)
            case .cancelExport(let operationID):
                await state.cancelExport(operationID: operationID)
            case .shutdown:
                await state.shutdown()
                try await writer.send(.shutdownComplete)
                return
            }
        }
    }

    private static func isolateProtocolOutput() throws -> Int32 {
        let descriptor = Darwin.dup(STDOUT_FILENO)
        guard descriptor >= 0 else {
            throw EvaluationError.processFailed("Unable to duplicate worker protocol output.")
        }
        guard Darwin.dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            Darwin.close(descriptor)
            throw EvaluationError.processFailed("Unable to redirect worker stdout to diagnostics.")
        }
        return descriptor
    }

    private static func readFramePayload(from descriptor: Int32) throws -> Data {
        var header = [UInt8](repeating: 0, count: RenderWorkerFraming.headerByteCount)
        try readExactly(descriptor, into: &header)
        let length = header.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        guard length > 0, length <= RenderWorkerFraming.maximumPayloadBytes else {
            throw EvaluationError.invalidResult("Worker frame length is outside the 1 MiB bound.")
        }
        var payload = [UInt8](repeating: 0, count: Int(length))
        try readExactly(descriptor, into: &payload)
        return Data(payload)
    }

    private static func readExactly(_ descriptor: Int32, into bytes: inout [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let result = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress!.advanced(by: offset), remaining)
            }
            if result > 0 {
                offset += result
                continue
            }
            if result == -1, errno == EINTR { continue }
            if result == 0 { throw EvaluationError.processFailed("Worker protocol ended inside a frame.") }
            throw EvaluationError.processFailed("Worker protocol read failed: \(String(cString: strerror(errno)))")
        }
    }

    fileprivate static func publish(_ loop: PreparedLoop, revision: UInt64, generation: UInt64, to outputURL: URL) throws {
        try loop.validate()
        let result = WorkerPreparedResult(revision: revision, generation: generation, loop: loop)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(result)
        guard data.count <= maximumResultBytes else {
            throw EvaluationError.invalidResult("Worker PCM result exceeds 16 MiB.")
        }
        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: outputURL, options: .atomic)
    }
}

private actor RenderWorkerOutputWriter {
    private let fileDescriptor: Int32
    private var tail: Task<Void, Error>?

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    func send(_ response: RenderWorkerResponse) async throws {
        let frame = try RenderWorkerFraming.encode(response)
        let descriptor = fileDescriptor
        let previous = tail
        let writeTask = Task.detached(priority: .userInitiated) {
            if let previous { try await previous.value }
            try frame.withUnsafeBytes { raw in
                guard let baseAddress = raw.baseAddress else {
                    throw EvaluationError.invalidResult("Worker response has no storage.")
                }
                var offset = 0
                while offset < frame.count {
                    let result = Darwin.write(descriptor, baseAddress.advanced(by: offset), frame.count - offset)
                    if result > 0 {
                        offset += result
                        continue
                    }
                    if result == -1, errno == EINTR { continue }
                    let reason = result == -1 ? String(cString: strerror(errno)) : "zero-byte write"
                    throw EvaluationError.processFailed("Worker response write failed: \(reason)")
                }
            }
        }
        tail = writeTask
        try await writeTask.value
    }
}

private actor RenderWorkerState {
    private struct Request: Sendable {
        let generation: UInt64
        let operationID: UInt64
        let overrides: [LiveControlOverride]
        let destination: URL?
    }

    private let session: LoopRenderSession
    private let revision: UInt64
    private let outputURL: URL
    private let writer: RenderWorkerOutputWriter
    private var activeRender: (operationID: UInt64, generation: UInt64, task: Task<Void, Never>)?
    private var pendingRender: Request?
    private var activeExport: (operationID: UInt64, generation: UInt64, task: Task<Void, Never>)?
    private var pendingExport: Request?
    private var latestOperationID: UInt64 = 0
    private var stopping = false

    init(session: LoopRenderSession, revision: UInt64, outputURL: URL, writer: RenderWorkerOutputWriter) {
        self.session = session
        self.revision = revision
        self.outputURL = outputURL
        self.writer = writer
    }

    func submit(
        revision: UInt64,
        generation: UInt64,
        operationID: UInt64,
        overrides: [LiveControlOverride]
    ) async throws {
        try await submit(
            Request(generation: generation, operationID: operationID, overrides: overrides, destination: nil),
            revision: revision
        )
    }

    func submitExport(
        revision: UInt64,
        generation: UInt64,
        operationID: UInt64,
        overrides: [LiveControlOverride],
        destination: URL
    ) async throws {
        try await submit(
            Request(generation: generation, operationID: operationID, overrides: overrides, destination: destination),
            revision: revision
        )
    }

    func cancelExport(operationID: UInt64) async {
        if let pendingExport, pendingExport.operationID == operationID {
            self.pendingExport = nil
            await reportFailure(pendingExport, message: "Stem export cancelled before rendering.")
            return
        }
        guard let activeExport, activeExport.operationID == operationID else { return }
        activeExport.task.cancel()
    }

    private func submit(_ request: Request, revision commandRevision: UInt64) async throws {
        guard !stopping else { throw CancellationError() }
        guard commandRevision == revision else {
            try await reportFailure(request, message: "Worker revision does not match.")
            return
        }
        guard request.operationID > latestOperationID else {
            try await reportFailure(request, message: "Worker operation is stale.")
            return
        }
        latestOperationID = request.operationID
        if request.destination == nil {
            if let pendingRender {
                self.pendingRender = nil
                await reportFailure(pendingRender, message: "Render superseded by a newer operation.")
            }
            if let activeRender {
                activeRender.task.cancel()
                pendingRender = request
            } else {
                start(request)
            }
        } else {
            if let pendingExport {
                self.pendingExport = nil
                await reportFailure(pendingExport, message: "Stem export superseded by a newer operation.")
            }
            if let activeExport {
                activeExport.task.cancel()
                pendingExport = request
            } else {
                start(request)
            }
        }
    }

    func shutdown() async {
        stopping = true
        pendingRender = nil
        pendingExport = nil
        if let activeRender {
            activeRender.task.cancel()
            await activeRender.task.value
            self.activeRender = nil
        }
        if let activeExport {
            activeExport.task.cancel()
            await activeExport.task.value
            self.activeExport = nil
        }
    }

    private func start(_ request: Request) {
        let session = session
        let writer = writer
        let outputURL = outputURL
        let revision = revision
        let workspace = outputURL.deletingLastPathComponent().standardizedFileURL.path
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            var committed = false
            do {
                if let destination = request.destination {
                    let standardizedDestination = destination.standardizedFileURL.path
                    guard standardizedDestination != workspace,
                          !standardizedDestination.hasPrefix(workspace + "/") else {
                        throw StemExportError.invalidDestination
                    }
                    let stems = try session.renderStems(overrides: request.overrides)
                    try Task.checkCancellation()
                    let manifest = try StemExporter.export(stems, to: destination)
                    committed = true
                    let snapshot = StemExportSnapshot(
                        revision: revision,
                        generation: request.generation,
                        manifest: manifest
                    )
                    try await writer.send(.stemsExported(snapshot: snapshot, operationID: request.operationID))
                } else {
                    let loop = try session.render(overrides: request.overrides)
                    try Task.checkCancellation()
                    try RenderWorker.publish(loop, revision: revision, generation: request.generation, to: outputURL)
                    try Task.checkCancellation()
                    try await writer.send(.rendered(revision: revision, generation: request.generation,
                                                    operationID: request.operationID))
                }
                await self?.finished(request)
            } catch {
                if error is CancellationError {
                    // A cancellation observed after the atomic directory rename cannot
                    // revoke the committed export. The response remains the authority.
                    if committed {
                        await self?.finished(request)
                        return
                    }
                    await self?.cancelled(request)
                } else {
                    await self?.reportFailure(request, error: error)
                    await self?.finished(request)
                }
            }
        }
        if request.destination == nil {
            activeRender = (request.operationID, request.generation, task)
        } else {
            activeExport = (request.operationID, request.generation, task)
        }
    }

    private func cancelled(_ request: Request) async {
        if request.destination == nil {
            guard let activeRender, activeRender.operationID == request.operationID else { return }
            self.activeRender = nil
            await reportFailure(request, message: "Render superseded or cancelled.")
            startPendingRenderIfAvailable()
        } else {
            guard let activeExport, activeExport.operationID == request.operationID else { return }
            self.activeExport = nil
            await reportFailure(request, message: "Stem export superseded or cancelled.")
            startPendingExportIfAvailable()
        }
    }

    private func finished(_ request: Request) async {
        if request.destination == nil {
            guard activeRender?.operationID == request.operationID else { return }
            activeRender = nil
            startPendingRenderIfAvailable()
        } else {
            guard activeExport?.operationID == request.operationID else { return }
            activeExport = nil
            startPendingExportIfAvailable()
        }
    }

    private func startPendingRenderIfAvailable() {
        guard let pendingRender else { return }
        self.pendingRender = nil
        start(pendingRender)
    }

    private func startPendingExportIfAvailable() {
        guard let pendingExport else { return }
        self.pendingExport = nil
        start(pendingExport)
    }

    private func reportFailure(_ request: Request, error: Error) async {
        await reportFailure(request, message: String(describing: error))
    }

    private func reportFailure(_ request: Request, message: String) async {
        do {
            try await writer.send(.failed(revision: revision, generation: request.generation,
                                          operationID: request.operationID, message: message))
        } catch {
            stopping = true
        }
    }
}
