import Foundation
import SwiftMusic

public struct SampleLoadRequest: Sendable {
    public let fileURL: URL
    public let region: SampleRegion?
    public let sampleRate: Double
    public let maximumChannelFrames: Int

    public init(fileURL: URL, region: SampleRegion? = nil,
                sampleRate: Double = PreparedLoop.requiredSampleRate, maximumChannelFrames: Int) {
        self.fileURL = fileURL.standardizedFileURL
        self.region = region
        self.sampleRate = sampleRate
        self.maximumChannelFrames = maximumChannelFrames
    }

    internal struct Key: Hashable {
        let fileURL: URL
        let region: SampleRegion?
        let sampleRate: Double
    }

    internal var key: Key { Key(fileURL: fileURL, region: region, sampleRate: sampleRate) }
}
