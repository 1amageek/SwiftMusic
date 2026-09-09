/// An explicit type-erasure boundary for a single sound declaration.
public struct AnySound: Sound {
    public typealias Body = Never
    private let content: any Sound

    public init<Content: Sound>(_ content: Content) { self.content = content }
    public var body: Never { fatalError("AnySound is a compiler terminal") }
}

extension AnySound: _SoundChildren {
    internal func _forEachChild(_ visit: (any Sound) throws -> Void) throws {
        try visit(content)
    }
}
