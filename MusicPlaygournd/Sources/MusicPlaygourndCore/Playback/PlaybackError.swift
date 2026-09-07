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
    case invalidPlaybackRate(Float)
    case invalidLowPassCutoff(Float)
    case invalidDelayMix(Float)
    case invalidReverbMix(Float)
    case offlineRenderingFailed(String)

    public var description: String {
        switch self {
        case .audioSetupFailed(let message): "Audio setup failed: \(message)"
        case .audioStartFailed(let message): "Audio start failed: \(message)"
        case .noCurrentLoop: "No prepared loop is available"
        case .staleRevision(let revision): "Revision \(revision) is stale"
        case .duplicateRevision(let revision): "Revision \(revision) was already submitted"
        case .updateNotStarted(let revision): "Revision \(revision) was not started"
        case .invalidLoop(let error): "Invalid prepared loop: \(error)"
        case .invalidPlaybackRate(let rate): "Playback rate \(rate) is outside 1/32...32"
        case .invalidLowPassCutoff(let cutoff): "Low-pass cutoff \(cutoff) is outside 20...20000 Hz"
        case .invalidDelayMix(let mix): "Delay mix \(mix) is outside 0...1"
        case .invalidReverbMix(let mix): "Reverb mix \(mix) is outside 0...1"
        case .offlineRenderingFailed(let message): "Offline rendering failed: \(message)"
        }
    }
}
