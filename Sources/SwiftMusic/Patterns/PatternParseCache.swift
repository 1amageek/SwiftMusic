/// Successful syntax preparation retained only for one compilation.
internal struct _PatternParseCache {
    private var programs: [String: (source: String, program: _PatternTimedProgram)] = [:]
    private var retainedBytes = 0
    private var retainedLeaves = 0
    private(set) var parseCount = 0

    mutating func parse(_ source: String) throws -> _PatternTimedProgram {
        // String equality is canonically equivalent; source offsets require exact UTF-8.
        if let cached = programs[source], cached.source.utf8.elementsEqual(source.utf8) {
            return cached.program
        }
        var parser = try _MiniPatternParser(source)
        parseCount += 1
        let program = try parser.parse()
        let bytes = source.utf8.count
        if let previous = programs.removeValue(forKey: source) {
            retainedBytes -= previous.source.utf8.count
            retainedLeaves -= previous.program.leaves.count
        }
        if bytes > _MiniPatternParser.maximumInputBytes - retainedBytes ||
            program.leaves.count > _MiniPatternParser.maximumLeaves - retainedLeaves {
            programs.removeAll(keepingCapacity: true)
            retainedBytes = 0
            retainedLeaves = 0
        }
        programs[source] = (source, program)
        retainedBytes += bytes
        retainedLeaves += program.leaves.count
        return program
    }
}
