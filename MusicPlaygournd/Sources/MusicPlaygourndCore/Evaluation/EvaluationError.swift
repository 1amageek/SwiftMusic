import Foundation

public enum EvaluationError: Error, LocalizedError, Sendable {
    case invalidSource(String)
    case processFailed(String)
    case timedOut(String)
    case invalidResult(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSource(let message), .processFailed(let message),
             .timedOut(let message), .invalidResult(let message): message
        }
    }
}
