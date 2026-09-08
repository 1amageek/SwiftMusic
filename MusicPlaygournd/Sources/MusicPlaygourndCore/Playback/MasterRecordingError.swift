import Foundation

public enum MasterRecordingError: Error, Equatable, Sendable, LocalizedError {
    case invalidSamples
    case invalidRequest
    case alreadyRecording
    case notRecording
    case destinationExists
    case unsupportedFormat
    case discontinuousTime
    case captureOverrun
    case durationExceeded
    case noSamples
    case conversionFailed
    case fileFailure(String)

    public var errorDescription: String? { String(describing: self) }
}
