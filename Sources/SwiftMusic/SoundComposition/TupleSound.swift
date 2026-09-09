/// A parallel composition that retains the concrete types of its children.
public struct TupleSound<Value: Sendable>: Sound {
    public typealias Body = Never
    public let value: Value

    private let visitChildren: @Sendable (borrowing Value, (any Sound) throws -> Void) throws -> Void

    public init<each Content: Sound>(_ value: (repeat each Content)) where Value == (repeat each Content) {
        self.value = value
        visitChildren = { value, visit in
            for child in repeat each value { try visit(child) }
        }
    }

    public var body: Never { fatalError("TupleSound is a compiler terminal") }
}

extension TupleSound: _SoundChildren {
    internal func _forEachChild(_ visit: (any Sound) throws -> Void) throws {
        try visitChildren(value, visit)
    }
}
