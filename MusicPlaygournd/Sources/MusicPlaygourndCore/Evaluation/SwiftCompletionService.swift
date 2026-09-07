import Foundation

/// Provides semantic Swift edits independently of the playback evaluator.
public actor SwiftCompletionService {
    private let packageURL: URL
    private let workspace: URL
    private let executable: String
    private var connection: SwiftCompletionConnection?
    private var startup: Task<SwiftCompletionConnection, Error>?
    private var generation = 0
    private var version = 0
    private var closed = false
    private static let prefix = "import SwiftMusic\n"

    public init(packageURL: URL, workspace: URL, sourceKitLSPExecutable: String) {
        self.packageURL = packageURL
        self.workspace = workspace
        executable = sourceKitLSPExecutable
    }

    public func completions(source: String, utf16Offset: Int) async throws -> [SwiftCompletion] {
        guard !closed else { throw SwiftCompletionError.shutdown }
        guard source.utf8.count <= 65_536 else { throw SwiftCompletionError.invalidSource("Source exceeds 64 KiB.") }
        guard utf16Offset >= 0, utf16Offset <= source.utf16.count,
              Range(NSRange(location: utf16Offset, length: 0), in: source) != nil else {
            throw SwiftCompletionError.invalidCursor(utf16Offset)
        }
        generation += 1
        let requested = generation
        let start = Self.identifierStart(in: source, cursor: utf16Offset)
        let completionSource = (source as NSString).replacingCharacters(in: NSRange(location: start, length: utf16Offset - start), with: "")
        let server = try await server(source: completionSource)
        try Task.checkCancellation()
        guard requested == generation else { throw SwiftCompletionError.staleRequest }
        let document = Self.prefix + completionSource
        let uri = workspace.appending(path: "Sources/CompletionSession/Session.swift").absoluteString
        version += 1
        let currentVersion = version
        do {
            try await server.notify(method: "textDocument/didChange", parameters: Self.json([
                "textDocument": ["uri": uri, "version": currentVersion], "contentChanges": [["text": document]]
            ]))
            try Task.checkCancellation()
            guard requested == generation else { throw SwiftCompletionError.staleRequest }
            let position = Self.position(in: document, offset: Self.prefix.utf16.count + start)
            let isMember = start > 0 && (source as NSString).character(at: start - 1) == 46
            let context: [String: Any] = isMember ? ["triggerKind": 2, "triggerCharacter": "."] : ["triggerKind": 1]
            let response = try await server.request(method: "textDocument/completion", parameters: Self.json([
                "textDocument": ["uri": uri], "position": position, "context": context
            ]), timeout: .seconds(30))
            try Task.checkCancellation()
            guard requested == generation else { throw SwiftCompletionError.staleRequest }
            return try Self.decode(response, source: source, cursor: utf16Offset)
        } catch is CancellationError {
            throw CancellationError()
        } catch SwiftCompletionError.staleRequest {
            throw SwiftCompletionError.staleRequest
        } catch {
            if connection === server {
                connection = nil
                try await server.shutdown()
            }
            throw error
        }
    }

    private func server(source: String) async throws -> SwiftCompletionConnection {
        if let connection { return connection }
        if let startup { return try await startup.value }
        let package = packageURL
        let directory = workspace
        let executable = executable
        let task = Task {
            let sourceDirectory = directory.appending(path: "Sources/CompletionSession")
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            let manifest = """
            // swift-tools-version: 6.4
            import PackageDescription
            let package = Package(name: "CompletionSession", platforms: [.macOS(.v15)], dependencies: [
                .package(path: \(Self.swiftLiteral(package.deletingLastPathComponent().path)))
            ], targets: [.executableTarget(name: "CompletionSession", dependencies: [.product(name: "SwiftMusic", package: "SwiftMusic")])])
            """
            try manifest.write(to: directory.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
            try (Self.prefix + source).write(to: sourceDirectory.appending(path: "Session.swift"), atomically: true, encoding: .utf8)
            let server = SwiftCompletionConnection(executable: executable, workspace: directory)
            do {
                try await server.start()
                _ = try await server.request(method: "initialize", parameters: Self.json([
                    "processId": ProcessInfo.processInfo.processIdentifier,
                    "rootUri": directory.absoluteString,
                    "capabilities": ["textDocument": ["completion": ["completionItem": ["snippetSupport": true]]]],
                    "workspaceFolders": [["uri": directory.absoluteString, "name": "CompletionSession"]]
                ]), timeout: .seconds(30))
                try await server.notify(method: "initialized", parameters: Self.json([:]))
                let uri = sourceDirectory.appending(path: "Session.swift").absoluteString
                try await server.notify(method: "textDocument/didOpen", parameters: Self.json([
                    "textDocument": ["uri": uri, "languageId": "swift", "version": 0, "text": Self.prefix + source]
                ]))
                // Initialization is shared by later edits and survives individual request cancellation.
                _ = try await server.request(method: "workspace/synchronize", parameters: Self.json(["index": true]), timeout: .seconds(60))
                return server
            } catch {
                try await server.shutdown()
                throw error
            }
        }
        startup = task
        do {
            let result = try await task.value
            startup = nil
            guard !closed else {
                try await result.shutdown()
                throw SwiftCompletionError.shutdown
            }
            connection = result
            return result
        } catch {
            startup = nil
            throw error
        }
    }

    public func shutdown() async throws {
        closed = true
        generation += 1
        startup?.cancel()
        if let startup {
            do { try await startup.value.shutdown() }
            catch is CancellationError { }
        }
        startup = nil
        if let connection { try await connection.shutdown() }
        connection = nil
        if FileManager.default.fileExists(atPath: workspace.path) {
            try FileManager.default.removeItem(at: workspace)
        }
    }

    private static func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func swiftLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // SourceKit completes at the identifier start; the editor filters the typed suffix.
    private static func identifierStart(in source: String, cursor: Int) -> Int {
        let text = source as NSString
        var start = cursor
        while start > 0 {
            let value = text.character(at: start - 1)
            guard (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value) || value == 95 else { break }
            start -= 1
        }
        return start
    }

    private static func position(in text: String, offset: Int) -> [String: Int] {
        let text = text as NSString
        var line = 0
        var start = 0
        for index in 0..<offset where text.character(at: index) == 10 { line += 1; start = index + 1 }
        return ["line": line, "character": offset - start]
    }

    private static func offset(_ position: [String: Any], in text: String) throws -> Int {
        guard let line = position["line"] as? Int, let character = position["character"] as? Int,
              line >= 0, character >= 0 else { throw SwiftCompletionError.malformedResponse("Invalid UTF-16 position.") }
        let text = text as NSString
        var current = 0
        var start = 0
        while current < line, start < text.length {
            if text.character(at: start) == 10 { current += 1 }
            start += 1
        }
        guard current == line else { throw SwiftCompletionError.malformedResponse("Line exceeds document.") }
        var end = start
        while end < text.length, text.character(at: end) != 10, text.character(at: end) != 13 { end += 1 }
        guard character <= end - start else { throw SwiftCompletionError.malformedResponse("Column exceeds line.") }
        return start + character
    }

    static func decode(_ data: Data, source: String, cursor: Int) throws -> [SwiftCompletion] {
        let response = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let result: Any
        if let envelope = response as? [String: Any], envelope["jsonrpc"] != nil {
            if let error = envelope["error"] { throw SwiftCompletionError.protocolError(String(describing: error)) }
            result = envelope["result"] ?? NSNull()
        } else { result = response }
        if result is NSNull { return [] }
        guard let items = (result as? [String: Any])?["items"] as? [[String: Any]] ?? result as? [[String: Any]] else {
            throw SwiftCompletionError.malformedResponse("Completion items are missing.")
        }
        let identifierOffset = identifierStart(in: source, cursor: cursor)
        let typedPrefix = (source as NSString).substring(with: NSRange(location: identifierOffset, length: cursor - identifierOffset))
        let document = prefix + (source as NSString).replacingCharacters(in: NSRange(location: identifierOffset, length: cursor - identifierOffset), with: "")
        var values: [SwiftCompletion] = []
        var rejected = false
        for item in items {
            guard let label = item["label"] as? String,
                  (item["additionalTextEdits"] as? [Any] ?? []).isEmpty else { continue }
            guard label.hasPrefix(typedPrefix) else { continue }
            let edit = item["textEdit"] as? [String: Any]
            guard let insertion = edit?["newText"] as? String ?? item["insertText"] as? String ?? item["label"] as? String else { continue }
            do {
                let range: NSRange
                if let bounds = edit?["range"] as? [String: Any] ?? edit?["replace"] as? [String: Any],
                   let start = bounds["start"] as? [String: Any], let end = bounds["end"] as? [String: Any] {
                    let first = try offset(start, in: document) - prefix.utf16.count
                    let last = try offset(end, in: document) - prefix.utf16.count
                    guard first >= 0, last >= first, last <= source.utf16.count - typedPrefix.utf16.count else {
                        throw SwiftCompletionError.malformedResponse("Edit exceeds source.")
                    }
                    guard first <= identifierOffset, last >= identifierOffset else {
                        throw SwiftCompletionError.malformedResponse("Edit does not cover the completion position.")
                    }
                    range = NSRange(location: first, length: last + typedPrefix.utf16.count - first)
                } else {
                    range = NSRange(location: identifierOffset, length: cursor - identifierOffset)
                }
                guard Range(range, in: source) != nil else { throw SwiftCompletionError.malformedResponse("Edit splits Unicode.") }
                let decoded = try decodeSnippet(insertion, enabled: (item["insertTextFormat"] as? Int) == 2)
                values.append(SwiftCompletion(label: label, detail: item["detail"] as? String,
                    insertion: decoded.0, replacementRange: range, selectionRange: decoded.1))
                if values.count == 256 { break }
            } catch let error as SwiftCompletionError {
                switch error {
                case .malformedResponse, .unsupportedSnippet: rejected = true; continue
                default: throw error
                }
            }
        }

        if rejected, values.isEmpty { throw SwiftCompletionError.malformedResponse("No supported completion edit.") }
        return values
    }

    static func decodeSnippet(_ snippet: String, enabled: Bool) throws -> (String, NSRange?) {
        guard snippet.utf8.count <= 65_536 else { throw SwiftCompletionError.unsupportedSnippet("Insertion exceeds 64 KiB.") }
        if !enabled { return (snippet, nil) }
        guard !snippet.contains("\\") else { throw SwiftCompletionError.unsupportedSnippet(snippet) }
        let expression = try NSRegularExpression(pattern: #"\$\{([0-9]+):([^{}]*)\}|\$\{([0-9]+)\}|\$([0-9]+)"#)
        let input = snippet as NSString
        var result = ""
        var end = 0
        var selection: NSRange?
        var selectedIndex = Int.max
        for match in expression.matches(in: snippet, range: NSRange(location: 0, length: input.length)) {
            let literal = input.substring(with: NSRange(location: end, length: match.range.location - end))
            guard !literal.contains("$") else { throw SwiftCompletionError.unsupportedSnippet(snippet) }
            result += literal
            guard let indexRange = [1, 3, 4].map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }),
                  let index = Int(input.substring(with: indexRange)) else {
                throw SwiftCompletionError.unsupportedSnippet(snippet)
            }
            let defaultRange = match.range(at: 2)
            let value = defaultRange.location == NSNotFound ? "" : input.substring(with: defaultRange)
            if index > 0, index < selectedIndex {
                selectedIndex = index
                selection = NSRange(location: result.utf16.count, length: value.utf16.count)
            }
            result += value
            end = NSMaxRange(match.range)
        }
        let suffix = input.substring(from: end)
        guard !suffix.contains("$") else { throw SwiftCompletionError.unsupportedSnippet(snippet) }
        result += suffix
        return (result, selection)
    }
}
