import Foundation

public enum PlaybackError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public var errorDescription: String? { description }

    case audioSetupFailed(String)
    case audioStartFailed(String)
    case noCurrentLoop
    case staleRevision(UInt64)
    case duplicateRevision(UInt64)
    case updateNotStarted(UInt64)
    case invalidLoop(PreparedLoopValidationError)

    public var description: String {
        switch self {
        case .audioSetupFailed(let message): "Audio setup failed: \(message)"
        case .audioStartFailed(let message): "Audio start failed: \(message)"
        case .noCurrentLoop: "No prepared loop is available"
        case .staleRevision(let revision): "Revision \(revision) is stale"
        case .duplicateRevision(let revision): "Revision \(revision) was already submitted"
        case .updateNotStarted(let revision): "Revision \(revision) was not started"
        case .invalidLoop(let error): "Invalid prepared loop: \(error)"
        }
    }
}
