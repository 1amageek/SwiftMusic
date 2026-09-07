import Foundation

public enum SwiftCompletionError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case invalidSource(String)
    case invalidCursor(Int)
    case executableUnavailable(String)
    case workspaceFailed(String)
    case processFailed(String)
    case processExited(Int32)
    case timedOut(String)
    case protocolError(String)
    case malformedResponse(String)
    case unsupportedSnippet(String)
    case staleRequest
    case shutdown

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .invalidSource(let message): "Invalid completion source: \(message)"
        case .invalidCursor(let offset): "Completion cursor UTF-16 offset \(offset) is outside the source."
        case .executableUnavailable(let path): "SourceKit-LSP executable is unavailable: \(path)"
        case .workspaceFailed(let message): "Completion workspace failed: \(message)"
        case .processFailed(let message): "SourceKit-LSP process failed: \(message)"
        case .processExited(let status): "SourceKit-LSP exited with status \(status)."
        case .timedOut(let message): "Swift completion timed out: \(message)"
        case .protocolError(let message): "SourceKit-LSP protocol error: \(message)"
        case .malformedResponse(let message): "Malformed SourceKit-LSP completion: \(message)"
        case .unsupportedSnippet(let snippet): "Unsupported SourceKit-LSP snippet: \(snippet)"
        case .staleRequest: "A newer completion request superseded this request."
        case .shutdown: "Swift completion service has been shut down."
        }
    }
}
