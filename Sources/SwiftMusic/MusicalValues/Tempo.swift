/// A tempo mapping kept independent from a compiled sound.
public struct Tempo: Sendable, Equatable {
    public let beatsPerMinute: Double
    public let beatUnit: MusicalTime

    public init(
        beatsPerMinute: Double,
        beatUnit: MusicalTime = .quarter
    ) throws {
        guard beatsPerMinute.isFinite else {
            throw TempoError.nonFiniteBeatsPerMinute
        }
        guard beatsPerMinute > 0 else {
            throw TempoError.nonPositiveBeatsPerMinute
        }
        guard beatUnit > .zero else {
            throw TempoError.zeroBeatUnit
        }
        self.beatsPerMinute = beatsPerMinute
        self.beatUnit = beatUnit
    }

    public static func bpm(
        _ beatsPerMinute: Double,
        beat beatUnit: MusicalTime = .quarter
    ) throws -> Tempo {
        try Tempo(beatsPerMinute: beatsPerMinute, beatUnit: beatUnit)
    }

    public func seconds(for time: MusicalTime) throws -> Double {
        let beats = Double(time.numerator) / Double(time.denominator)
        let beatUnit = Double(beatUnit.numerator) / Double(beatUnit.denominator)
        let seconds = beats / beatUnit * 60 / beatsPerMinute
        guard seconds.isFinite else {
            throw TempoError.nonFiniteSeconds
        }
        return seconds
    }
}
