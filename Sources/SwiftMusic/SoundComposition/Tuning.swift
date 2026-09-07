public struct Tuning: Sendable, Equatable, Hashable {
    public let referencePitch: Pitch
    public let frequencyHz: Double

    public init(referencePitch: Pitch, frequencyHz: Double) throws {
        guard frequencyHz.isFinite, frequencyHz > 0 else {
            throw SoundParameterError.invalidValue("frequencyHz")
        }
        self.referencePitch = referencePitch
        self.frequencyHz = frequencyHz
    }
}
