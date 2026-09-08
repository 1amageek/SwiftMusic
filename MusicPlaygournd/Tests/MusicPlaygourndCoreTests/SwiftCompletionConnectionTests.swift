import Foundation
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
struct SwiftCompletionConnectionTests {
    @Test(.timeLimit(.minutes(3)))
    func testFrameParserHandlesSplitHeaderAndBody() throws {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"result":[]}"#.utf8)
        let frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
        var parser = SwiftCompletionFrameParser()
        var frames: [Data] = []
        for byte in frame {
            frames.append(contentsOf: try parser.append(byte))
        }
        #expect(frames == [body])
        var invalid = SwiftCompletionFrameParser()
        #expect {
            try Data("Content-Length: -1\r\n\r\n".utf8).forEach { _ = try invalid.append($0) }
        } throws: { error in
            if case SwiftCompletionError.protocolError = error { return true }
            return false
        }
    }

    @Test(.timeLimit(.minutes(3)),
        .enabled(if: try SwiftCompletionConnectionTests.resolveSourceKitLSP() != nil,
                 "The Swift 6.4 SourceKit-LSP toolchain is unavailable."))
    func testRealSourceKitLSPInitializeAndBoundedShutdown() async throws {
        let executable = try #require(try Self.resolveSourceKitLSP())

        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "SwiftCompletionConnection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let connection = SwiftCompletionConnection(executable: executable)
        var failure: Error?
        do {
            try await connection.start()
            let workspaceURI = workspace.absoluteString
            let parameters = try JSONSerialization.data(withJSONObject: [
                "processId": NSNull(),
                "rootUri": workspaceURI,
                "capabilities": ["textDocument": ["completion": ["completionItem": ["snippetSupport": true]]]],
                "workspaceFolders": [["uri": workspaceURI, "name": "CompletionConnection"]]
            ])
            let response = try await connection.request(
                method: "initialize",
                parameters: parameters,
                timeout: .seconds(30)
            )
            let object = try #require(try JSONSerialization.jsonObject(with: response) as? [String: Any])
            #expect((object["id"] as? NSNumber)?.intValue == 1)
            #expect(object["result"] as? [String: Any] != nil)
            try await connection.notify(method: "initialized", parameters: Data("{}".utf8))
        } catch {
            failure = error
        }

        do {
            try await connection.shutdown()
        } catch {
            if failure == nil { failure = error }
        }
        do {
            try FileManager.default.removeItem(at: workspace)
        } catch {
            if failure == nil { failure = error }
        }
        if let failure { throw failure }
    }

    @Test(.timeLimit(.minutes(3)))
    func testUnresponsiveInitializationTimesOutAndShutsDown() async throws {
        let (workspace, executable) = try makeUnresponsiveFixture()
        let connection = SwiftCompletionConnection(executable: executable.path, workspace: workspace)
        var failure: Error?
        do {
            try await connection.start()
            let parameters = try JSONSerialization.data(withJSONObject: ["processId": 1])
            do {
                _ = try await connection.request(method: "initialize", parameters: parameters, timeout: .milliseconds(200))
                failure = SwiftCompletionError.protocolError("The unresponsive test process unexpectedly returned a response.")
            } catch let error as SwiftCompletionError {
                if case .timedOut = error {
                } else {
                    failure = error
                }
            } catch {
                failure = error
            }
            try await connection.shutdown()
        } catch {
            failure = error
        }
        do {
            try FileManager.default.removeItem(at: workspace)
        } catch {
            if failure == nil { failure = error }
        }
        if let failure { throw failure }
    }

    @Test(.timeLimit(.minutes(3)))
    func testCancelledInitializationCanShutdownWithPendingRequest() async throws {
        let (workspace, executable) = try makeUnresponsiveFixture()
        let connection = SwiftCompletionConnection(executable: executable.path, workspace: workspace)
        var failure: Error?
        do {
            try await connection.start()
            let parameters = try JSONSerialization.data(withJSONObject: ["processId": 1])
            let request = Task { () -> String in
                do {
                    _ = try await connection.request(method: "initialize", parameters: parameters, timeout: .seconds(30))
                    return "completed"
                } catch is CancellationError {
                    return "cancelled"
                } catch {
                    return String(describing: error)
                }
            }
            try await Task.sleep(for: .milliseconds(100))
            request.cancel()
            try await connection.shutdown()
            let result = await request.value
            if result != "cancelled" {
                failure = SwiftCompletionError.protocolError("Cancelled initialization returned \(result).")
            }
        } catch {
            failure = error
        }
        do {
            try FileManager.default.removeItem(at: workspace)
        } catch {
            if failure == nil { failure = error }
        }
        if let failure { throw failure }
    }

    @Test(.timeLimit(.minutes(3)))
    func testLargeRequestDoesNotBlockActorWhenPeerDoesNotRead() async throws {
        let (workspace, executable) = try makeUnresponsiveFixture()
        let connection = SwiftCompletionConnection(executable: executable.path, workspace: workspace)
        var failure: Error?
        do {
            try await connection.start()
            let parameters = try JSONSerialization.data(withJSONObject: ["payload": String(repeating: "x", count: 1_000_000)])
            let request = Task { () -> String in
                do {
                    _ = try await connection.request(method: "initialize", parameters: parameters, timeout: .seconds(2))
                    return "completed"
                } catch {
                    return String(describing: error)
                }
            }
            let result = await request.value
            if result == "completed" {
                failure = SwiftCompletionError.protocolError("The unresponsive test process unexpectedly returned a response.")
            }
            try await connection.shutdown()
        } catch {
            failure = error
        }
        do {
            try FileManager.default.removeItem(at: workspace)
        } catch {
            if failure == nil { failure = error }
        }
        if let failure { throw failure }
    }

    @Test(.timeLimit(.minutes(3)))
    func testServerRequestsAreAnsweredWithoutCompletingClientRequest() async throws {
        let (workspace, executable) = try makeServerRequestFixture()
        let connection = SwiftCompletionConnection(executable: executable.path, workspace: workspace)
        var failure: Error?
        do {
            try await connection.start()
            let response = try await connection.request(
                method: "initialize",
                parameters: Data(#"{"processId":1}"#.utf8),
                timeout: .seconds(2)
            )
            let object = try #require(try JSONSerialization.jsonObject(with: response) as? [String: Any])
            #expect((object["id"] as? NSNumber)?.intValue == 1)
            #expect(object["result"] != nil)
            try await connection.shutdown()
        } catch {
            failure = error
        }
        do {
            try FileManager.default.removeItem(at: workspace)
        } catch {
            if failure == nil { failure = error }
        }
        if let failure { throw failure }
    }

    @Test(.timeLimit(.minutes(3)))
    func testCancelledShutdownCompletesProcessCleanup() async throws {
        let (workspace, executable) = try makeUnresponsiveFixture()
        let connection = SwiftCompletionConnection(executable: executable.path, workspace: workspace)
        var failure: Error?
        do {
            try await connection.start()
            let shutdown = Task { () -> String in
                do {
                    try await connection.shutdown()
                    return "completed"
                } catch is CancellationError {
                    return "cancelled"
                } catch {
                    return String(describing: error)
                }
            }
            shutdown.cancel()
            let result = await shutdown.value
            if result != "cancelled" {
                failure = SwiftCompletionError.protocolError("Cancelled shutdown returned \(result).")
            }
            do {
                _ = try await connection.request(
                    method: "initialize",
                    parameters: Data(#"{"processId":1}"#.utf8),
                    timeout: .milliseconds(200)
                )
                failure = SwiftCompletionError.protocolError("The cancelled shutdown left a live connection.")
            } catch let error as SwiftCompletionError {
                if case .processExited = error {
                } else {
                    failure = error
                }
            } catch {
                failure = error
            }
            try await connection.shutdown()
        } catch {
            failure = error
        }
        do {
            try FileManager.default.removeItem(at: workspace)
        } catch {
            if failure == nil { failure = error }
        }
        if let failure { throw failure }
    }

    static func resolveSourceKitLSP() throws -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "sourcekit-lsp"]
        process.standardOutput = output
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    private func makeUnresponsiveFixture() throws -> (workspace: URL, executable: URL) {
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "SwiftCompletionConnection-Unresponsive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let executable = workspace.appending(path: "unresponsive.py")
        let script = "#!/usr/bin/env python3\nimport time\nwhile True:\n    time.sleep(60)\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (workspace, executable)
    }

    private func makeServerRequestFixture() throws -> (workspace: URL, executable: URL) {
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "SwiftCompletionConnection-ServerRequest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let executable = workspace.appending(path: "server-request.py")
        let script = #"""
#!/usr/bin/env python3
import json
import sys

def receive():
    header = b""
    while b"\r\n\r\n" not in header:
        byte = sys.stdin.buffer.read(1)
        if not byte:
            raise SystemExit(2)
        header += byte
    length = int(header.split(b":", 1)[1].split(b"\r", 1)[0])
    body = b""
    while len(body) < length:
        chunk = sys.stdin.buffer.read(length - len(body))
        if not chunk:
            raise SystemExit(3)
        body += chunk
    return json.loads(body)

def send(value):
    body = json.dumps(value, separators=(",", ":")).encode()
    sys.stdout.buffer.write(("Content-Length: %d\r\n\r\n" % len(body)).encode() + body)
    sys.stdout.buffer.flush()

request = receive()
send({"jsonrpc": "2.0", "id": 99, "method": "workspace/configuration", "params": {}})
configuration = receive()
if configuration.get("id") != 99 or configuration.get("result") != [] or "error" in configuration:
    raise SystemExit(4)
send({"jsonrpc": "2.0", "id": 100, "method": "window/workDoneProgress/create", "params": {}})
progress = receive()
if progress.get("id") != 100 or progress.get("result", "missing") is not None or "error" in progress:
    raise SystemExit(5)
send({"jsonrpc": "2.0", "id": request.get("id"), "result": {}})
"""#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (workspace, executable)
    }
}

}
