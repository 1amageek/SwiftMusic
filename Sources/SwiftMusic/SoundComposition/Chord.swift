public struct Chord: Sendable, Equatable, Hashable {
    public let intervals: [Semitones]

    public init(intervals: [Semitones]) throws {
        guard (1...16).contains(intervals.count) else {
            throw SoundParameterError.invalidValue("chord intervals")
        }
        self.intervals = intervals
    }

    private init(_ values: [Double]) {
        intervals = values.map { try! Semitones(value: $0) }
    }

    public static let major = Chord([0, 4, 7])
    public static let minor = Chord([0, 3, 7])
    public static let power = Chord([0, 7])
    public static let dominantSeventh = Chord([0, 4, 7, 10])
}
