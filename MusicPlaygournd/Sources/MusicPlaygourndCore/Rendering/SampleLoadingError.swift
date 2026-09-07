import Foundation

public enum SampleLoadingError: Error, Sendable, Equatable {
    case invalidFileURL(URL)
    case unreadableFile(URL)
    case unsupportedFormat(URL)
    case unsupportedChannelCount(Int)
    case invalidSampleRate(Double)
    case invalidFrameCount(Int64)
    case conversionFailed(URL)
    case truncatedOutput(expected: Int, actual: Int)
    case nonFinitePCM(index: Int)
}
