import Foundation

public enum StemExportError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case invalidDestination
    case destinationExists
    case tooManyStems
    case duplicateTrack
    case invalidStem(String)
    case stagingFailed(String)
    case writeFailed(String)
    case cleanupFailed(original: String, cleanup: String)

    public var description: String {
        switch self {
        case .invalidDestination: return "Stem export destination must be an absolute file URL."
        case .destinationExists: return "Stem export destination already exists."
        case .tooManyStems: return "Stem export exceeds the 32-track bound."
        case .duplicateTrack: return "Stem export contains duplicate Track identity."
        case let .invalidStem(reason): return "Stem is invalid: \(reason)"
        case let .stagingFailed(reason): return "Stem staging failed: \(reason)"
        case let .writeFailed(reason): return "Stem write failed: \(reason)"
        case let .cleanupFailed(original, cleanup):
            return "Stem export failed: \(original); cleanup failed: \(cleanup)"
        }
    }

    public var errorDescription: String? { description }
}
