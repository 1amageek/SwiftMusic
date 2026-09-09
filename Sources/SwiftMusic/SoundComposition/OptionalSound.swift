/// An absent optional sound contributes no events or duration.
extension Optional: Sound where Wrapped: Sound {
    public typealias Body = Never
    public var body: Never { fatalError("Optional Sound is a compiler terminal") }
}

extension Optional: _SoundChildren where Wrapped: Sound {
    internal func _forEachChild(_ visit: (any Sound) throws -> Void) throws {
        if let content = self { try visit(content) }
    }
}
