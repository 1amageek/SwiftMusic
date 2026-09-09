/// A finite parallel composition produced by a builder's for loop.
public struct ArraySound<Content: Sound>: Sound {
    public typealias Body = Never
    public let content: [Content]

    public init(_ content: [Content]) { self.content = content }
    public var body: Never { fatalError("ArraySound is a compiler terminal") }
}

extension ArraySound: _SoundChildren {
    internal func _forEachChild(_ visit: (any Sound) throws -> Void) throws {
        for child in content { try visit(child) }
    }
}
