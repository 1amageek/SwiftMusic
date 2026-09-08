import Foundation

/// Metadata returned after a complete stem directory has been published.
public struct StemExportManifest: Codable, Sendable, Equatable {
    public let trackID: Int
    public let label: String
    public let fileName: String
    public let sampleRate: Double
    public let bpm: Double
    public let beatsPerBar: Int
    public let beatCount: Double
    public let frameCount: Int

    internal init(stem: PreparedStem, fileName: String) {
        self.trackID = stem.trackID
        self.label = stem.label
        self.fileName = fileName
        self.sampleRate = stem.sampleRate
        self.bpm = stem.bpm
        self.beatsPerBar = stem.beatsPerBar
        self.beatCount = stem.beatCount
        self.frameCount = stem.frameCount
    }
}
