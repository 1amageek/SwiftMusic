/// An optional named grouping boundary that preserves child timing and graph shape.
public struct Track: Sound, Sendable {
    public typealias Body = Never

    public let name: String
    internal let content: SoundGroup

    public init(
        _ name: String,
        @SoundBuilder content: () -> SoundGroup
    ) {
        self.name = name
        self.content = content()
    }

    public var body: Never {
        fatalError("Track is a compiler terminal")
    }
}

extension Track: _SoundPrimitive {
    internal var _node: _SoundNode {
        .track(name, content)
    }
}
