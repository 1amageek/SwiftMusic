/// A one-based scale degree, with zero and negative values continuing below tonic.
public struct ScaleDegree: Sendable, Equatable, Hashable {
    public let value: Int

    public init(_ value: Int) {
        self.value = value
    }
}
