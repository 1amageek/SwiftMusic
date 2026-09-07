/// A signed logarithmic level measured in decibels.
public struct Decibels: Sendable, Hashable {
    public let value: Double

    public init(value: Double) throws {
        guard value.isFinite else {
            throw SoundParameterError.invalidValue("decibels")
        }
        self.value = value
    }
}
