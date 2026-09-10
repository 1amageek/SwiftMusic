/// A tonic pitch paired with a validated scale.
public struct Key: Sendable, Equatable, Hashable {
    public let tonic: Pitch
    public let scale: Scale

    public init(tonic: Pitch, scale: Scale) {
        self.tonic = tonic
        self.scale = scale
    }
}
