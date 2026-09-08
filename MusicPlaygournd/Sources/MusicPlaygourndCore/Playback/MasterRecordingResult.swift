import Foundation

public struct MasterRecordingResult: Sendable {
    public let destination: URL
    public let frameCount: Int64
    public let sampleRate: Double
    public let channelCount: Int
    public let inputFrameCount: Int64
    public let inputSampleRate: Double
    public let largestInputBuffer: Int
}
