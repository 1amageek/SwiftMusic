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
            case .render(let commandRevision, let generation, let overrides):
                try await state.submit(revision: commandRevision, generation: generation, overrides: overrides)
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
        let overrides: [LiveControlOverride]
    }

    private let session: LoopRenderSession
    private let revision: UInt64
    private let outputURL: URL
    private let writer: RenderWorkerOutputWriter
    private var active: (generation: UInt64, task: Task<Void, Never>)?
    private var pending: Request?
    private var latestGeneration: UInt64 = 0
    private var stopping = false

    init(session: LoopRenderSession, revision: UInt64, outputURL: URL, writer: RenderWorkerOutputWriter) {
        self.session = session
        self.revision = revision
        self.outputURL = outputURL
        self.writer = writer
    }

    func submit(revision: UInt64, generation: UInt64, overrides: [LiveControlOverride]) async throws {
        guard !stopping else { throw CancellationError() }
        guard revision == self.revision else {
            try await writer.send(.failed(revision: self.revision, generation: generation,
                                          message: "Worker revision does not match."))
            return
        }
        guard generation > latestGeneration else {
            try await writer.send(.failed(revision: self.revision, generation: generation,
                                          message: "Worker generation is stale."))
            return
        }
        latestGeneration = generation
        if let pending {
            self.pending = nil
            try await writer.send(.failed(revision: self.revision, generation: pending.generation,
                                          message: "Render superseded by a newer generation."))
        }
        let request = Request(generation: generation, overrides: overrides)
        if let active {
            active.task.cancel()
            pending = request
        } else {
            start(request)
        }
    }

    func shutdown() async {
        stopping = true
        pending = nil
        if let active {
            active.task.cancel()
            await active.task.value
            self.active = nil
        }
    }

    private func start(_ request: Request) {
        let session = session
        let writer = writer
        let outputURL = outputURL
        let revision = revision
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let loop = try session.render(overrides: request.overrides)
                try Task.checkCancellation()
                try RenderWorker.publish(loop, revision: revision, generation: request.generation, to: outputURL)
                try Task.checkCancellation()
                try await writer.send(.rendered(revision: revision, generation: request.generation))
                await self?.finished(request.generation)
            } catch is CancellationError {
                await self?.cancelled(request.generation)
            } catch {
                await self?.reportFailure(generation: request.generation, error: error)
                await self?.finished(request.generation)
            }
        }
        active = (request.generation, task)
    }

    private func cancelled(_ generation: UInt64) async {
        guard active?.generation == generation else { return }
        active = nil
        await reportFailure(generation: generation, message: "Render superseded or cancelled.")
        startPendingIfAvailable()
    }

    private func finished(_ generation: UInt64) async {
        guard active?.generation == generation else { return }
        active = nil
        startPendingIfAvailable()
    }

    private func startPendingIfAvailable() {
        guard let pending else { return }
        self.pending = nil
        start(pending)
    }

    private func reportFailure(generation: UInt64, error: Error) async {
        await reportFailure(generation: generation, message: String(describing: error))
    }

    private func reportFailure(generation: UInt64, message: String) async {
        do {
            try await writer.send(.failed(revision: revision, generation: generation, message: message))
        } catch {
            stopping = true
        }
    }
}
