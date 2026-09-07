/// A deferred sequence of hit (`x`) and rest (`~`) steps.
public struct RhythmPattern: Sendable, Equatable, ExpressibleByStringLiteral {
    /// The source text retained by a literal or an eagerly validated value.
    public let rawValue: String

    /// Creates and eagerly validates a pattern from dynamic text.
    public init(_ value: String) throws {
        _ = try Self.parse(value)
        rawValue = value
    }

    /// Requests eager validation explicitly, including when the argument is a literal.
    public init(validating value: String) throws {
        try self.init(value)
    }

    /// Creates and eagerly validates a pattern from explicit steps.
    public init(steps: [Bool]) throws {
        guard !steps.isEmpty else {
            throw RhythmPatternError.emptyInput
        }
        guard steps.count <= _MiniPatternParser.maximumLeaves else {
            throw RhythmPatternError.tooManyLeaves(limit: _MiniPatternParser.maximumLeaves, offset: 0)
        }
        rawValue = steps.map { $0 ? "x" : "~" }.joined(separator: " ")
    }

    /// Retains literal input without validating it during Swift source evaluation.
    public init(stringLiteral value: String) {
        rawValue = value
    }

    /// Resolves the source text for the compiler.
    public var steps: [Bool] {
        get throws {
            try Self.parse(rawValue)
        }
    }

    /// Resolves the source text into its bounded natural-period program.
    internal var timedProgram: _PatternTimedProgram {
        get throws { try Self.parseTimedProgram(rawValue) }
    }

    /// Resolves the source text into exact recursive leaf timings for compilation.
    internal var timedLeaves: [_PatternTimedLeaf] {
        get throws { try timedProgram.leaves }
    }

    private static func parse(_ value: String) throws -> [Bool] {
        try parseTimedProgram(value).leaves.map { leaf in
            switch leaf.token {
            case "x": return true
            case "~": return false
            default:
                throw RhythmPatternError.invalidToken(token: leaf.token, index: leaf.index, offset: leaf.offset)
            }
        }
    }

    private static func parseTimedProgram(_ value: String) throws -> _PatternTimedProgram {
        do {
            var parser = try _MiniPatternParser(value)
            let program = try parser.parse()
            for leaf in program.leaves {
                guard leaf.token == "x" || leaf.token == "~" else {
                    throw RhythmPatternError.invalidToken(token: leaf.token, index: leaf.index, offset: leaf.offset)
                }
            }
            return program
        } catch let error as RhythmPatternError {
            throw error
        } catch let error as _PatternParserError {
            throw map(error)
        }
    }

    private static func map(_ error: _PatternParserError) -> RhythmPatternError {
        switch error {
        case .emptyInput: return .emptyInput
        case .emptyGroup(let offset): return .emptyGroup(offset: offset)
        case .invalidToken(let token, let index, let offset):
            return .invalidToken(token: token, index: index, offset: offset)
        case .invalidRepetition(let token, let index, let offset):
            return .invalidRepetition(token: token, index: index, offset: offset)
        case .unmatchedOpeningBracket(let offset): return .unmatchedOpeningBracket(offset: offset)
        case .unmatchedClosingBracket(let offset): return .unmatchedClosingBracket(offset: offset)
        case .unmatchedOpeningAngleBracket(let offset): return .unmatchedOpeningAngleBracket(offset: offset)
        case .unmatchedClosingAngleBracket(let offset): return .unmatchedClosingAngleBracket(offset: offset)
        case .inputTooLong(let limit, let offset): return .inputTooLong(limit: limit, offset: offset)
        case .tooManyLeaves(let limit, let offset): return .tooManyLeaves(limit: limit, offset: offset)
        case .nestingTooDeep(let limit, let offset): return .nestingTooDeep(limit: limit, offset: offset)
        case .timingOverflow(let offset): return .timingOverflow(offset: offset)
        }
    }
}
