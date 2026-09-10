/// Deterministic signed timing and velocity offset ranges for event humanization.
public struct Humanization: Sendable, Equatable, Hashable {
    public let timingStep: MusicalTime
    public let timingOffsets: ClosedRange<Int>
    public let velocityOffsets: ClosedRange<Int>
    public let seed: UInt64

    /// Creates a bounded humanization descriptor with exact timing arithmetic.
    public init(
        timingStep: MusicalTime,
        timingOffsets: ClosedRange<Int>,
        velocityOffsets: ClosedRange<Int>,
        seed: UInt64
    ) throws {
        guard
            let timingChoiceCount = Self.choiceCount(timingOffsets),
            timingChoiceCount <= 1_024,
            let velocityChoiceCount = Self.choiceCount(velocityOffsets),
            velocityChoiceCount <= 1_024
        else {
            throw RhythmTransformError.invalidHumanization
        }

        if timingStep.numerator == 0 {
            guard timingOffsets.lowerBound == 0, timingOffsets.upperBound == 0 else {
                throw RhythmTransformError.invalidHumanization
            }
        } else {
            for offset in timingOffsets {
                do {
                    _ = try timingStep.multiplied(by: UInt64(offset.magnitude))
                } catch {
                    throw RhythmTransformError.invalidHumanization
                }
            }
        }

        self.timingStep = timingStep
        self.timingOffsets = timingOffsets
        self.velocityOffsets = velocityOffsets
        self.seed = seed
    }

    private static func choiceCount(_ range: ClosedRange<Int>) -> UInt64? {
        guard range.lowerBound <= range.upperBound else { return nil }
        let (distance, distanceOverflowed) = range.upperBound.subtractingReportingOverflow(range.lowerBound)
        guard !distanceOverflowed else { return nil }
        let (count, countOverflowed) = distance.addingReportingOverflow(1)
        guard !countOverflowed, count >= 0 else { return nil }
        return UInt64(count)
    }
}
