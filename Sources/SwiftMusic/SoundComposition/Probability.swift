/// A deterministic event-retention probability and its explicit random seed.
public struct Probability: Sendable, Equatable, Hashable {
    public let chance: Double
    public let seed: UInt64

    /// Creates a probability descriptor in the inclusive unit interval.
    public init(chance: Double, seed: UInt64) throws {
        guard chance.isFinite, (0.0...1.0).contains(chance) else {
            throw RhythmTransformError.invalidProbability
        }
        self.chance = chance
        self.seed = seed
    }
}
