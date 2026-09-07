import Darwin
import Foundation

/// Owns one framed JSON-RPC connection to a dedicated SourceKit-LSP process.
actor SwiftCompletionConnection {
    static let maximumMessageBytes = 4 * 1024 * 1024

    private let executable: String
    private let workspace: URL?
    private var process: Process?
    private var input: FileHandle?
    private var childInput: FileHandle?
    private var output: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var isClosed = true
    private var shutdownRequested = false

    init(executable: String) {
        self.executable = executable
        workspace = nil
    }

    init(executable: String, workspace: URL) {
        self.executable = executable
        self.workspace = workspace
    }

    func start() async throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw SwiftCompletionError.executableUnavailable(executable)
        }

        let process = Process()
        let inputPair: (parent: FileHandle, child: FileHandle)
        do {
            inputPair = try Self.makeInputSocketPair()
        } catch let error as SwiftCompletionError {
            throw error
        } catch {
            throw SwiftCompletionError.processFailed(String(describing: error))
        }
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", Self.processRunner, executable]
        process.currentDirectoryURL = workspace
        process.standardInput = inputPair.child
        process.standardOutput = outputPipe
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        process.terminationHandler = { [weak self] process in
            Task { await self?.processTerminated(status: process.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            throw SwiftCompletionError.processFailed(String(describing: error))
        }

        self.process = process
        input = inputPair.parent
        childInput = inputPair.child
        output = outputPipe.fileHandleForReading
        isClosed = false
        shutdownRequested = false

        let output = outputPipe.fileHandleForReading
        readerTask = Task { [weak self] in
            do {
                var parser = SwiftCompletionFrameParser()
                for try await byte in output.bytes {
                    let frames = try parser.append(byte)
                    for frame in frames {
                        await self?.deliver(frame)
                    }
                }
                await self?.processTerminated(status: -1)
            } catch {
                await self?.fail(error)
            }
        }
    }

    func request(method: String, parameters: Data, timeout: Duration) async throws -> Data {
        guard !isClosed, process != nil else {
            throw SwiftCompletionError.processExited(-1)
        }
        let requestID = nextRequestID
        nextRequestID = requestID == Int.max ? 1 : requestID + 1
        let params = try JSONSerialization.jsonObject(with: parameters)
        let body = try Self.jsonData([
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": params
        ])

        return try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { [self] in
                    try await self.awaitResponse(body: body, requestID: requestID)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw SwiftCompletionError.timedOut("The SourceKit-LSP request exceeded its bound.")
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw SwiftCompletionError.protocolError("The request completed without a response.")
                }
                return result
            }
        }, onCancel: {
            Task { await self.cancel(requestID: requestID) }
        })
    }

    func notify(method: String, parameters: Data) async throws {
        let params = try JSONSerialization.jsonObject(with: parameters)
        let body = try Self.jsonData([
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ])
        try write(body)
    }

    func shutdown() async throws {
        guard !isClosed || process != nil || input != nil || output != nil else { return }
        let cancellationRequested = Task.isCancelled
        shutdownRequested = true
        let continuations = Array(pending.values)
        pending.removeAll(keepingCapacity: false)
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }

        var terminated = true
        if let process, process.isRunning {
            terminated = false
            terminate(process)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            terminated = await Self.waitUntilTerminated(process, deadline: deadline)
            if process.isRunning {
                let processID = process.processIdentifier
                if processID > 0 { _ = kill(-processID, SIGKILL) }
                process.terminate()
                let killDeadline = ContinuousClock.now.advanced(by: .seconds(1))
                terminated = await Self.waitUntilTerminated(process, deadline: killDeadline)
            }
            terminated = !process.isRunning
        }

        isClosed = true
        readerTask?.cancel()
        readerTask = nil
        try input?.close()
        try childInput?.close()
        try output?.close()
        input = nil
        childInput = nil
        output = nil
        process = nil
        guard terminated else {
            throw SwiftCompletionError.processFailed("SourceKit-LSP did not terminate within the shutdown bound.")
        }
        if cancellationRequested || Task.isCancelled {
            throw CancellationError()
        }
    }

    private func awaitResponse(body: Data, requestID: Int) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                guard !isClosed else {
                    continuation.resume(throwing: SwiftCompletionError.processExited(-1))
                    return
                }
                pending[requestID] = continuation
                do {
                    try write(body)
                } catch {
                    pending.removeValue(forKey: requestID)?.resume(throwing: error)
                }
            }
        }, onCancel: {
            Task { await self.cancel(requestID: requestID) }
        })
    }

    private func cancel(requestID: Int) {
        guard let continuation = pending.removeValue(forKey: requestID) else { return }
        continuation.resume(throwing: CancellationError())
        do {
            let body = try Self.jsonData([
                "jsonrpc": "2.0",
                "method": "$/cancelRequest",
                "params": ["id": requestID]
            ])
            try write(body)
        } catch {
            // The request is already cancelled; the next completion will report process state.
        }
    }

    private func write(_ body: Data) throws {
        guard body.count <= Self.maximumMessageBytes else {
            throw SwiftCompletionError.protocolError("The JSON-RPC message exceeds 4 MiB.")
        }
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        guard !isClosed, let input, input.fileDescriptor >= 0 else {
            throw SwiftCompletionError.processExited(-1)
        }
        var offset = 0
        // Data owns this initialized byte buffer; the pointer stays inside this synchronous borrow.
        // Positive writes advance only within frame.count; the actor exclusively owns the descriptor.
        try frame.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            while offset < frame.count {
                let count = Darwin.write(input.fileDescriptor, baseAddress.advanced(by: offset), frame.count - offset)
                if count > 0 {
                    offset += count
                    continue
                }
                if count == -1, errno == EINTR { continue }
                if count == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                    throw SwiftCompletionError.processFailed("SourceKit-LSP input is not writable within the current bounded operation.")
                }
                if count == -1, errno == EPIPE || errno == ECONNRESET {
                    throw SwiftCompletionError.processExited(-1)
                }
                let reason = count == -1 ? String(cString: strerror(errno)) : "zero-byte write"
                throw SwiftCompletionError.processFailed("Unable to write the SourceKit-LSP request: \(reason)")
            }
        }
    }

    private func deliver(_ body: Data) {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                fail(SwiftCompletionError.malformedResponse("The JSON-RPC response is not an object."))
                return
            }
            object = decoded
        } catch {
            fail(SwiftCompletionError.malformedResponse(String(describing: error)))
            return
        }
        if let method = object["method"] as? String, let number = object["id"] as? NSNumber {
            do {
                let response: Data
                switch method {
                case "workspace/configuration":
                    response = try Self.jsonData(["jsonrpc": "2.0", "id": number, "result": []])
                case "window/workDoneProgress/create", "client/registerCapability", "client/unregisterCapability":
                    response = try Self.jsonData(["jsonrpc": "2.0", "id": number, "result": NSNull()])
                default:
                    response = try Self.jsonData([
                        "jsonrpc": "2.0",
                        "id": number,
                        "error": ["code": -32601, "message": "Method not supported: \(method)"]
                    ])
                }
                try write(response)
            } catch {
                fail(error)
            }
            return
        }
        if object["method"] != nil {
            return
        }
        guard let number = object["id"] as? NSNumber else {
            fail(SwiftCompletionError.malformedResponse("The JSON-RPC response has no id."))
            return
        }
        let requestID = number.intValue
        guard let continuation = pending.removeValue(forKey: requestID) else { return }
        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? -1
            let message = error["message"] as? String ?? "Unknown LSP error"
            continuation.resume(throwing: SwiftCompletionError.protocolError("\(code): \(message)"))
        } else {
            continuation.resume(returning: body)
        }
    }

    private func fail(_ error: Error) {
        guard !isClosed else { return }
        isClosed = true
        let continuations = Array(pending.values)
        pending.removeAll(keepingCapacity: false)
        for continuation in continuations { continuation.resume(throwing: error) }
        if let process { terminate(process) }
    }

    private func processTerminated(status: Int32) {
        guard !isClosed || !pending.isEmpty else { return }
        isClosed = true
        process = nil
        let continuations = Array(pending.values)
        pending.removeAll(keepingCapacity: false)
        let error: Error = shutdownRequested
            ? CancellationError()
            : SwiftCompletionError.processExited(status)
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    private func terminate(_ process: Process) {
        let processID = process.processIdentifier
        if processID > 0 { _ = kill(-processID, SIGTERM) }
        process.terminate()
    }

    private static func jsonData(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw SwiftCompletionError.protocolError("Unable to encode an LSP message.")
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func waitUntilTerminated(
        _ process: Process,
        deadline: ContinuousClock.Instant
    ) async -> Bool {
        let waiter = Task { () -> Bool in
            while process.isRunning {
                guard ContinuousClock.now < deadline else { return false }
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    return false
                }
            }
            return true
        }
        return await waiter.value
    }

    private static func makeInputSocketPair() throws -> (parent: FileHandle, child: FileHandle) {
        var descriptors = [Int32](repeating: -1, count: 2)
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        guard result == 0 else {
            throw SwiftCompletionError.processFailed("Unable to create the SourceKit-LSP input socket: \(String(cString: strerror(errno)))")
        }

        let parentDescriptor = descriptors[0]
        let childDescriptor = descriptors[1]
        do {
            var flags = fcntl(parentDescriptor, F_GETFL, 0)
            guard flags >= 0 else {
                throw SwiftCompletionError.processFailed("Unable to inspect the SourceKit-LSP input socket: \(String(cString: strerror(errno)))")
            }
            flags |= O_NONBLOCK
            guard fcntl(parentDescriptor, F_SETFL, flags) == 0 else {
                throw SwiftCompletionError.processFailed("Unable to make the SourceKit-LSP input non-blocking: \(String(cString: strerror(errno)))")
            }
            var noSignal: Int32 = 1
            guard setsockopt(
                parentDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw SwiftCompletionError.processFailed("Unable to configure the SourceKit-LSP input socket: \(String(cString: strerror(errno)))")
            }
        } catch {
            _ = Darwin.close(parentDescriptor)
            _ = Darwin.close(childDescriptor)
            throw error
        }

        return (
            FileHandle(fileDescriptor: parentDescriptor, closeOnDealloc: true),
            FileHandle(fileDescriptor: childDescriptor, closeOnDealloc: true)
        )
    }

    private static let processRunner = """
    import os, signal, subprocess, sys
    os.setpgid(0, 0)
    child = subprocess.Popen(sys.argv[1:], stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr)
    try:
        status = child.wait()
    except BaseException:
        try:
            os.killpg(os.getpid(), signal.SIGKILL)
        except ProcessLookupError:
            pass
        status = 137
    sys.exit(status if status >= 0 else 128 - status)
    """
}
