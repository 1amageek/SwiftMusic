/// A deterministic event transform selected on every Nth rhythm cycle.
public struct PeriodicRhythmTransform: Sendable, Equatable, Hashable {
    public let every: UInt64
    public let phase: UInt64
    public let cycle: MusicalTime
    public let transform: RhythmEventTransform

    /// Creates a periodic transform and validates its cycle-local operation.
    public init(
        every: UInt64,
        phase: UInt64 = 0,
        cycle: MusicalTime = .whole,
        transform: RhythmEventTransform
    ) throws {
        guard (1...1_024).contains(every), cycle.numerator != 0 else {
            throw RhythmTransformError.invalidPeriodicTransform
        }
        if case .ratcheted(let count) = transform, !(1...1_024).contains(count) {
            throw RhythmTransformError.invalidPeriodicTransform
        }

        self.every = every
        self.phase = phase % every
        self.cycle = cycle
        self.transform = transform
    }
}
