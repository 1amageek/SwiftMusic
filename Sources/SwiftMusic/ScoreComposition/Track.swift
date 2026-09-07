/// An optional named grouping boundary that preserves child timing.
public struct Track: Score, Sendable {
    public typealias Body = Never

    public let name: String
    internal let content: ScoreGroup

    public init(
        _ name: String,
        @ScoreBuilder content: () -> ScoreGroup
    ) {
        self.name = name
        self.content = content()
    }

    public var body: Never {
        fatalError("Track is a compiler terminal")
    }
}

extension Track: _ScorePrimitive {
    internal func _visit(
        in context: inout _ScoreCompilationContext,
        depth: Int
    ) throws -> MusicalTime {
        try context.visit(track: self, depth: depth)
    }
}
