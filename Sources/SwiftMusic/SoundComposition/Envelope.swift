public struct Envelope: Sendable, Equatable, Hashable {
    public let attackSeconds: Double
    public let decaySeconds: Double
    public let sustainLevel: Double
    public let releaseSeconds: Double

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
