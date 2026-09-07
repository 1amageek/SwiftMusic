import Foundation

/// Owns decoded interleaved PCM; value copies share immutable Array storage.
public struct LoadedSample: Sendable {
    public let samples: [Float]
    public let channelCount: Int
    public let sampleRate: Double
    public var frameCount: Int { samples.count / channelCount }

    public init(samples: [Float], channelCount: Int, sampleRate: Double) throws {
        guard (1...2).contains(channelCount) else {
            throw SampleLoadingError.unsupportedChannelCount(channelCount)
        }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw SampleLoadingError.invalidSampleRate(sampleRate)
        }
        guard !samples.isEmpty, samples.count % channelCount == 0 else {
            throw SampleLoadingError.invalidFrameCount(Int64(samples.count / channelCount))
        }
        if let index = samples.firstIndex(where: { !$0.isFinite }) {
            throw SampleLoadingError.nonFinitePCM(index: index)
        }
        self.samples = samples
        self.channelCount = channelCount
        self.sampleRate = sampleRate
    }
}
