/// A named sample source descriptor. Loading and playback belong to a client backend.
public struct Sample: Sound, Sendable, Equatable {
    public typealias Body = Never

    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public var body: Never {
        fatalError("Sample is a compiler terminal")
    }
}

extension Sample: _SoundPrimitive {
    internal var _node: _SoundNode {
        .sample(name)
    }
}
