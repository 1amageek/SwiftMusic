/// A declaration with no events, sources, tracks, or duration.
public struct EmptySound: Sound {
    public typealias Body = Never

    public init() {}
    public var body: Never { fatalError("EmptySound is a compiler terminal") }
}

extension EmptySound: _SoundChildren {
    internal func _forEachChild(_ visit: (any Sound) throws -> Void) throws {}
}
