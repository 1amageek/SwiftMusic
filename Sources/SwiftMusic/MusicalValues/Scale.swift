/// A finite, strictly increasing set of semitone intervals within one octave.
public struct Scale: Sendable, Equatable, Hashable {
    public let intervals: [Semitones]

    /// Creates a scale whose first interval is tonic zero.
    public init(intervals: [Semitones]) throws {
        guard (1...12).contains(intervals.count), let first = intervals.first, first.value == 0 else {
            throw HarmonyError.invalidScale
        }

        var previous: Double?
        for interval in intervals {
            let value = interval.value
            guard value.isFinite, value >= 0, value < 12 else {
                throw HarmonyError.invalidScale
            }
            if let previous, value <= previous {
                throw HarmonyError.invalidScale
            }
            previous = value
        }
        self.intervals = intervals
    }

    public static let chromatic = makeBuiltin([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
    public static let major = makeBuiltin([0, 2, 4, 5, 7, 9, 11])
    public static let naturalMinor = makeBuiltin([0, 2, 3, 5, 7, 8, 10])
    public static let majorPentatonic = makeBuiltin([0, 2, 4, 7, 9])
    public static let minorPentatonic = makeBuiltin([0, 3, 5, 7, 10])

    private static func makeBuiltin(_ values: [Double]) -> Scale {
        do {
            var intervals: [Semitones] = []
            intervals.reserveCapacity(values.count)
            for value in values {
                intervals.append(try Semitones(value: value))
            }
            return try Scale(intervals: intervals)
        } catch {
            preconditionFailure("Invalid built-in scale")
        }
    }
}
