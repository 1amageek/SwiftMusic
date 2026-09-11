/// Successful syntax preparation retained only for one compilation.
internal struct _PatternParseCache {
    private var programs: [String: _PatternTimedProgram] = [:]
    private var retainedBytes = 0
    private var retainedLeaves = 0
    private(set) var parseCount = 0

    mutating func parse(_ source: String) throws -> _PatternTimedProgram {
        if let program = programs[source] { return program }
        var parser = try _MiniPatternParser(source)
        parseCount += 1
        let program = try parser.parse()
        let bytes = source.utf8.count
        if bytes > _MiniPatternParser.maximumInputBytes - retainedBytes ||
            program.leaves.count > _MiniPatternParser.maximumLeaves - retainedLeaves {
            programs.removeAll(keepingCapacity: true)
            retainedBytes = 0
            retainedLeaves = 0
        }
        programs[source] = program
        retainedBytes += bytes
        retainedLeaves += program.leaves.count
        return program
    }
}
