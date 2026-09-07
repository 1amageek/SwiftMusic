/// The immutable package-owned value produced by `SoundBuilder`.
public struct SoundGroup: Sound, Sendable {
    public typealias Body = Never

    internal let elements: [any Sound]

    internal init(elements: [any Sound]) {
        self.elements = elements
    }

    public var body: Never {
        fatalError("SoundGroup is a compiler terminal")
    }
}

extension SoundGroup: _SoundPrimitive {
    internal var _node: _SoundNode {
        .group(elements)
    }
}
