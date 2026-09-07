/// A signed pitch interval, including fractional semitones.
public struct Semitones: Sendable, Hashable {
    public let value: Double

    public init(value: Double) throws {
        guard value.isFinite else {
            throw SoundParameterError.invalidValue("semitones")
        }
        self.value = value
    }
}
