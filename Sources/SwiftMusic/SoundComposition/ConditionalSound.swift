/// The selected branch of a declaration, retaining both possible branch types.
public struct ConditionalSound<TrueContent: Sound, FalseContent: Sound>: Sound {
    public typealias Body = Never

    internal enum Storage: Sendable {
        case first(TrueContent)
        case second(FalseContent)
    }

    internal let storage: Storage
    public var body: Never { fatalError("ConditionalSound is a compiler terminal") }
}

extension ConditionalSound: _SoundChildren {
    internal func _forEachChild(_ visit: (any Sound) throws -> Void) throws {
        switch storage {
        case .first(let content): try visit(content)
        case .second(let content): try visit(content)
        }
    }
}
