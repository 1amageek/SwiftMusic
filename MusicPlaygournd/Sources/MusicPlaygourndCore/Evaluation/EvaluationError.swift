import Foundation

public enum EvaluationError: Error, LocalizedError, Sendable {
    case invalidSource(String)
    case processFailed(String)
    case timedOut(String)
    case invalidResult(String)
    case workerCompilerDiagnostic(WorkerCompilerDiagnostic)
    case compilerDiagnostic(message: String, range: SourceDiagnosticRange?)

    public var errorDescription: String? {
        switch self {
        case .invalidSource(let message), .processFailed(let message),
             .timedOut(let message), .invalidResult(let message): message
        case .workerCompilerDiagnostic(let diagnostic):
            "\(diagnostic.domain): \(diagnostic.message) (\(diagnostic.fileID):\(diagnostic.line):\(diagnostic.column))"
        case .compilerDiagnostic(let message, let range):
            if let range {
                "\(message) (\(range.fileID):\(range.line):\(range.column))"
            } else {
                message
            }
        }
    }
}
