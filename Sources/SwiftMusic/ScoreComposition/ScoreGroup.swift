/// The package-owned value produced by `ScoreBuilder`.
public struct ScoreGroup: Score, Sendable {
    public typealias Body = Never

    internal let elements: [any Score]

    internal init(elements: [any Score]) {
        self.elements = elements
    }

    public var body: Never {
        fatalError("ScoreGroup is a compiler terminal")
    }
}

extension ScoreGroup: _ScorePrimitive {
    internal func _visit(
        in context: inout _ScoreCompilationContext,
        depth: Int
    ) throws -> MusicalTime {
        try context.visit(group: self, depth: depth)
    }
}
