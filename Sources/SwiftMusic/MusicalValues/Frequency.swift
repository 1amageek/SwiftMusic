/// A positive frequency measured in hertz.
public struct Frequency: Sendable, Hashable {
    public let hertz: Double

    public init(hertz: Double) throws {
        guard hertz.isFinite && hertz > 0 else {
            throw SoundParameterError.invalidValue("frequency")
        }
        self.hertz = hertz
    }
}
