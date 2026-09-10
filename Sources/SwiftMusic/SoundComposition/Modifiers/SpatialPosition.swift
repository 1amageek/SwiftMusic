/// Normalized stereo placement and stylized depth, validated during compilation.
public struct SpatialPosition: Sendable, Codable, Hashable {
    public var x: Double
    public var depth: Double
    public init(x: Double, depth: Double) { self.x = x; self.depth = depth }
}

public extension Sound {
    func position(_ value: SpatialPosition) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .position(value))
    }
}
