/// A pitched event at an explicit musical onset and duration.
public struct Note: Score, Sendable, Equatable {
    public typealias Body = Never

    public let pitch: Pitch
    public let start: MusicalTime
    public let duration: MusicalTime

    public init(pitch: Pitch, start: MusicalTime, duration: MusicalTime) {
        self.pitch = pitch
        self.start = start
        self.duration = duration
    }

    public var body: Never {
        fatalError("Note is a compiler terminal")
    }
}

extension Note: _ScorePrimitive {
    internal func _visit(
        in context: inout _ScoreCompilationContext,
        depth: Int
    ) throws -> MusicalTime {
        try context.append(note: self)
    }
}
