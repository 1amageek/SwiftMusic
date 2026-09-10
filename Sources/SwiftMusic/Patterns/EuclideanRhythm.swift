/// A bounded Euclidean hit distribution over an exact musical cycle.
public struct EuclideanRhythm: Sendable, Equatable, Hashable {
    public let pulses: Int
    public let steps: Int
    public let rotation: Int
    public let cycle: MusicalTime

    /// Creates a Euclidean rhythm and normalizes rotation into the step domain.
    public init(
        pulses: Int,
        steps: Int,
        rotation: Int = 0,
        cycle: MusicalTime = .whole
    ) throws {
        guard steps >= 1, steps <= 1_024, pulses >= 0, pulses <= steps, cycle.numerator != 0 else {
            throw RhythmTransformError.invalidEuclidean
        }

        let remainder = rotation % steps
        self.pulses = pulses
        self.steps = steps
        self.rotation = remainder >= 0 ? remainder : remainder + steps
        self.cycle = cycle
    }
}
