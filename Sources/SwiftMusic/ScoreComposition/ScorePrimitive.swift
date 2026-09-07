internal protocol _ScorePrimitive {
    func _visit(
        in context: inout _ScoreCompilationContext,
        depth: Int
    ) throws -> MusicalTime
}
