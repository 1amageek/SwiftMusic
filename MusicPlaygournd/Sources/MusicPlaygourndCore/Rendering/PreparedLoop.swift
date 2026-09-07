import Foundation

public struct PreparedLoop: Codable, Sendable, Equatable {
    public static let requiredSampleRate = 44_100.0
    public static let maximumDurationSeconds = 16.0
    public static let maximumBeatCount = 32.0
    public static let maximumEvents = 1_024

    public let sampleRate: Double
    public let bpm: Double
    public let beatsPerBar: Int
    public let beatCount: Double
    public let samples: [Float]
    public let events: [LoopEvent]

    public init(
        sampleRate: Double,
        bpm: Double,
        beatsPerBar: Int,
        beatCount: Double,
        samples: [Float],
        events: [LoopEvent]
    ) {
        self.sampleRate = sampleRate
        self.bpm = bpm
        self.beatsPerBar = beatsPerBar
        self.beatCount = beatCount
        self.samples = samples
        self.events = events
    }

    public func validate() throws {
        guard sampleRate == Self.requiredSampleRate else {
            throw PreparedLoopValidationError.invalidSampleRate(sampleRate)
        }
        guard bpm.isFinite, (40...240).contains(bpm) else {
            throw PreparedLoopValidationError.invalidBPM(bpm)
        }
        guard (2...7).contains(beatsPerBar) else {
            throw PreparedLoopValidationError.invalidMeter(beatsPerBar)
        }
        guard beatCount.isFinite,
              beatCount > 0,
              beatCount <= Self.maximumBeatCount else {
            throw PreparedLoopValidationError.invalidBeatCount(beatCount)
        }

        let barCount = (beatCount / Double(beatsPerBar)).rounded()
        guard barCount >= 1,
              abs(barCount * Double(beatsPerBar) - beatCount) <= 1e-9 else {
            throw PreparedLoopValidationError.invalidBeatCount(beatCount)
        }

        let duration = beatCount * 60 / bpm
        guard duration.isFinite, duration <= Self.maximumDurationSeconds else {
            throw PreparedLoopValidationError.invalidBeatCount(beatCount)
        }
        let expectedFrames = Int((duration * sampleRate).rounded(.up))
        guard expectedFrames >= 1, samples.count == expectedFrames * 2 else {
            throw PreparedLoopValidationError.invalidSampleCount(samples.count)
        }

        let maximumSamples = Int(Self.requiredSampleRate * Self.maximumDurationSeconds) * 2
        guard samples.count <= maximumSamples else {
            throw PreparedLoopValidationError.tooManySamples(limit: maximumSamples)
        }
        for (index, sample) in samples.enumerated() {
            guard sample.isFinite else {
                throw PreparedLoopValidationError.nonFiniteSample(index: index)
            }
        }

        guard events.count <= Self.maximumEvents else {
            throw PreparedLoopValidationError.tooManyEvents(limit: Self.maximumEvents)
        }
        var previousStart = 0.0
        for (index, event) in events.enumerated() {
            guard event.sourceID >= 0 else {
                throw PreparedLoopValidationError.invalidEvent(index: index, reason: "negative source ID")
            }
            guard !event.label.isEmpty else {
                throw PreparedLoopValidationError.invalidEvent(index: index, reason: "empty label")
            }
            guard event.startBeat.isFinite,
                  event.durationBeats.isFinite,
                  event.startBeat >= 0,
                  event.durationBeats > 0,
                  event.startBeat + event.durationBeats <= beatCount + 1e-9 else {
                throw PreparedLoopValidationError.invalidEvent(index: index, reason: "invalid timing")
            }
            guard event.startBeat + 1e-9 >= previousStart else {
                throw PreparedLoopValidationError.invalidEvent(index: index, reason: "events are not sorted")
            }
            previousStart = event.startBeat
            if let midiNote = event.midiNote, !(0...127).contains(midiNote) {
                throw PreparedLoopValidationError.invalidEvent(index: index, reason: "MIDI note is out of range")
            }
            guard (1...127).contains(event.velocity) else {
                throw PreparedLoopValidationError.invalidEvent(index: index, reason: "velocity is out of range")
            }
        }
    }
}
