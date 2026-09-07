/// A source-independent, immutable modifier wrapper.
public struct ModifiedSound: Sound, Sendable {
    public typealias Body = Never

    internal let base: any Sound
    internal let modifier: _SoundModifier

    internal init(base: any Sound, modifier: _SoundModifier) {
        self.base = base
        self.modifier = modifier
    }

    public var body: Never {
        fatalError("ModifiedSound is a compiler terminal")
    }
}

extension ModifiedSound: _SoundPrimitive {
    internal var _node: _SoundNode {
        .modified(base, modifier)
    }
}
