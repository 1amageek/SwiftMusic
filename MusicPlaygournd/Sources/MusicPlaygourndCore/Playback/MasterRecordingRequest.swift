import Foundation

public struct MasterRecordingRequest: Sendable {
    public enum Format: Sendable { case wavFloat32 }
    public let destination: URL
    public let format: Format
    public let maximumDuration: Duration
    internal let maximumFrames: Int64

    public init(destination: URL, format: Format = .wavFloat32, maximumDuration: Duration) throws {
        let parts = maximumDuration.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        let frames = (seconds * PreparedLoop.requiredSampleRate).rounded(.down)
        guard destination.isFileURL, seconds.isFinite, seconds > 0, frames >= 1,
              frames <= Double((UInt32.max - 4096) / 8) else { throw MasterRecordingError.invalidRequest }
        self.destination = destination
        self.format = format
        self.maximumDuration = maximumDuration
        self.maximumFrames = Int64(frames)
    }
}
