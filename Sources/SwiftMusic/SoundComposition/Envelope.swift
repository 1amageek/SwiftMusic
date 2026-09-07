public struct Envelope: Sendable, Equatable, Hashable {
    public let attackSeconds: Double
    public let decaySeconds: Double
    public let sustainLevel: Double
    public let releaseSeconds: Double

    /// Accepts standard-library durations while retaining the existing seconds representation.
    public init(attack: Duration, decay: Duration, sustainLevel: Double, release: Duration) throws {
        guard attack >= .zero, decay >= .zero, release >= .zero else {
            throw SoundParameterError.invalidValue("envelope duration")
        }
        func seconds(_ duration: Duration) -> Double {
            let parts = duration.components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }
        try self.init(attackSeconds: seconds(attack), decaySeconds: seconds(decay),
                      sustainLevel: sustainLevel, releaseSeconds: seconds(release))
    }

    public init(
        attackSeconds: Double,
        decaySeconds: Double,
        sustainLevel: Double,
        releaseSeconds: Double
    ) throws {
        let durations = [attackSeconds, decaySeconds, releaseSeconds]
        guard durations.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw SoundParameterError.invalidValue("envelope duration")
        }
        guard sustainLevel.isFinite, (0...1).contains(sustainLevel) else {
            throw SoundParameterError.invalidRange("sustainLevel")
        }
        self.attackSeconds = attackSeconds
        self.decaySeconds = decaySeconds
        self.sustainLevel = sustainLevel
        self.releaseSeconds = releaseSeconds
    }
}
