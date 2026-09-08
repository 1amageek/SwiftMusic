import Foundation

/// One stable Track boundary captured from the retained rendering graph.
public struct PreparedStem: Sendable, Equatable {
    public let trackID: Int
    public let label: String
    public let sampleRate: Double
    public let bpm: Double
    public let beatsPerBar: Int
    public let beatCount: Double
    public let samples: [Float]

    public var frameCount: Int { samples.count / 2 }

    public init(
        trackID: Int,
        label: String,
        sampleRate: Double,
        bpm: Double,
        beatsPerBar: Int,
        beatCount: Double,
        samples: [Float]
    ) throws {
        guard trackID >= 0, !label.isEmpty,
              sampleRate == PreparedLoop.requiredSampleRate,
              bpm.isFinite, (40...240).contains(bpm),
              (2...7).contains(beatsPerBar),
              beatCount.isFinite, beatCount > 0, beatCount <= PreparedLoop.maximumBeatCount,
              samples.count.isMultiple(of: 2), !samples.isEmpty,
              samples.allSatisfy(\.isFinite)
        else {
            throw StemExportError.invalidStem("Stem metadata or PCM is invalid.")
        }
        let duration = beatCount * 60 / bpm
        let expectedFrames = Int((duration * sampleRate).rounded(.up))
        guard expectedFrames > 0, samples.count == expectedFrames * 2,
              samples.count <= Int(PreparedLoop.requiredSampleRate * PreparedLoop.maximumDurationSeconds) * 2
        else {
            throw StemExportError.invalidStem("Stem PCM length does not match its loop metadata.")
        }
        self.trackID = trackID
        self.label = label
        self.sampleRate = sampleRate
        self.bpm = bpm
        self.beatsPerBar = beatsPerBar
        self.beatCount = beatCount
        self.samples = samples
    }
}
