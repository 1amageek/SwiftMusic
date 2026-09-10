public struct Envelope: Sendable, Equatable, Hashable {
    public let attackSeconds: Double
    public let decaySeconds: Double
    public let sustainLevel: Double
    public let releaseSeconds: Double
    public let attackCurve: EnvelopeCurve
    public let decayCurve: EnvelopeCurve
    public let releaseCurve: EnvelopeCurve
    public let releaseAnchor: EnvelopeReleaseAnchor

    /// Accepts standard-library durations while retaining the existing seconds representation.
    public init(
        attack: Duration,
        decay: Duration,
        sustainLevel: Double,
        release: Duration,
        attackCurve: EnvelopeCurve = .linear,
        decayCurve: EnvelopeCurve = .linear,
        releaseCurve: EnvelopeCurve = .linear,
        releaseAnchor: EnvelopeReleaseAnchor = .gateEnd
    ) throws {
        guard attack >= .zero, decay >= .zero, release >= .zero else {
            throw SoundParameterError.invalidValue("envelope duration")
        }
        func seconds(_ duration: Duration) -> Double {
            let parts = duration.components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }
        try self.init(attackSeconds: seconds(attack), decaySeconds: seconds(decay),
                      sustainLevel: sustainLevel, releaseSeconds: seconds(release),
                      attackCurve: attackCurve, decayCurve: decayCurve,
                      releaseCurve: releaseCurve, releaseAnchor: releaseAnchor)
    }

    public init(
        attackSeconds: Double,
        decaySeconds: Double,
        sustainLevel: Double,
        releaseSeconds: Double,
        attackCurve: EnvelopeCurve = .linear,
        decayCurve: EnvelopeCurve = .linear,
        releaseCurve: EnvelopeCurve = .linear,
        releaseAnchor: EnvelopeReleaseAnchor = .gateEnd
    ) throws {
        let durations = [attackSeconds, decaySeconds, releaseSeconds]
        guard durations.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw SoundParameterError.invalidValue("envelope duration")
        }
        guard sustainLevel.isFinite, (0...1).contains(sustainLevel) else {
            throw SoundParameterError.invalidRange("sustainLevel")
        }
        try Self.validate(attackCurve)
        try Self.validate(decayCurve)
        try Self.validate(releaseCurve)
        self.attackSeconds = attackSeconds
        self.decaySeconds = decaySeconds
        self.sustainLevel = sustainLevel
        self.releaseSeconds = releaseSeconds
        self.attackCurve = attackCurve
        self.decayCurve = decayCurve
        self.releaseCurve = releaseCurve
        self.releaseAnchor = releaseAnchor
    }

    private static func validate(_ curve: EnvelopeCurve) throws {
        guard case .exponential(let exponent) = curve else { return }
        guard exponent.isFinite, exponent > 0 else {
            throw SoundParameterError.invalidValue("envelope curve exponent")
        }
    }
}
