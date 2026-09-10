import Foundation

/// Immutable configuration for decoded-sample granular traversal.
public struct GranularPlayback: Sendable, Equatable, Hashable {
    public let grainDuration: Duration
    public let overlap: Double
    public let positionJitter: Double
    public let seed: UInt64

    public static let standard = GranularPlayback(
        uncheckedGrainDuration: .milliseconds(40),
        overlap: 0.5,
        positionJitter: 0,
        seed: 0
    )

    public init(
        grainDuration: Duration,
        overlap: Double,
        positionJitter: Double,
        seed: UInt64
    ) throws {
        let components = grainDuration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        guard grainDuration > .zero, seconds.isFinite, seconds > 0 else {
            throw SampleDescriptorError.invalidGranularDuration
        }
        guard overlap.isFinite, (0..<1).contains(overlap) else {
            throw SampleDescriptorError.invalidGranularOverlap(overlap)
        }
        guard positionJitter.isFinite, (0...1).contains(positionJitter) else {
            throw SampleDescriptorError.invalidGranularJitter(positionJitter)
        }
        self.init(
            uncheckedGrainDuration: grainDuration,
            overlap: overlap,
            positionJitter: positionJitter,
            seed: seed
        )
    }

    private init(
        uncheckedGrainDuration grainDuration: Duration,
        overlap: Double,
        positionJitter: Double,
        seed: UInt64
    ) {
        self.grainDuration = grainDuration
        self.overlap = overlap
        self.positionJitter = positionJitter
        self.seed = seed
    }
}
