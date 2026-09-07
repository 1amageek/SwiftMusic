/// A silent interval at an explicit musical onset and duration.
public struct Rest: Score, Sendable, Equatable {
    public typealias Body = Never

    public let start: MusicalTime
    public let duration: MusicalTime

    public init(start: MusicalTime, duration: MusicalTime) {
        self.start = start
        self.duration = duration
    }

    public var body: Never {
        fatalError("Rest is a compiler terminal")
    }
}

extension Rest: _ScorePrimitive {
    internal func _visit(
        in context: inout _ScoreCompilationContext,
        depth: Int
    ) throws -> MusicalTime {
        try context.account(rest: self)
    }
}
