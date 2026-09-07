public struct Chord: Sendable, Equatable, Hashable {
    public let intervals: [Int]

    private init(intervals: [Int]) {
        self.intervals = intervals
    }

    public static let major = Chord(intervals: [0, 4, 7])
    public static let minor = Chord(intervals: [0, 3, 7])
    public static let power = Chord(intervals: [0, 7])
    public static let dominantSeventh = Chord(intervals: [0, 4, 7, 10])
}
