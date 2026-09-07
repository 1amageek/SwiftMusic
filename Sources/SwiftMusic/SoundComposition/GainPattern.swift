/// A deferred recursively subdivided sequence of per-event gain values.
public struct GainPattern: Sendable, Equatable, ExpressibleByStringLiteral {
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

    /// Retains literal input without validating it during Swift source evaluation.
    public init(stringLiteral value: String) {
        rawValue = value
    }

    /// Resolves the source text into flat values for clients that need the legacy view.
    public var steps: [Double] {
        get throws {
            try Self.parse(rawValue)
        }
    }

    /// Resolves the source text into exact recursive leaf timings for compilation.
    internal var timedLeaves: [_PatternTimedLeaf] {
        get throws {
            try Self.parseTimedLeaves(rawValue)
        }
    }

    private static func parse(_ value: String) throws -> [Double] {
        try parseTimedLeaves(value).map { leaf in
            guard let gain = Double(leaf.token) else {
                throw GainPatternError.invalidToken(token: leaf.token, index: leaf.index)
            }
            return gain
        }
    }

    private static func parseTimedLeaves(_ value: String) throws -> [_PatternTimedLeaf] {
        do {
            var parser = try _MiniPatternParser(value)
            let leaves = try parser.parse()
            for leaf in leaves {
                guard leaf.token != "~" else {
                    throw GainPatternError.invalidToken(token: leaf.token, index: leaf.index)
                }
                guard let value = Double(leaf.token) else {
                    throw GainPatternError.invalidToken(token: leaf.token, index: leaf.index)
                }
                guard value.isFinite else {
                    throw GainPatternError.nonFiniteValue(token: leaf.token, index: leaf.index)
                }
                guard value >= 0 else {
                    throw GainPatternError.negativeValue(token: leaf.token, index: leaf.index)
                }
            }
            return leaves
        } catch let error as GainPatternError {
            throw error
        } catch let error as _PatternParserError {
            throw map(error)
        }
    }

    private static func map(_ error: _PatternParserError) -> GainPatternError {
        switch error {
        case .emptyInput: return .emptyInput
        case .emptyGroup(let offset): return .emptyGroup(offset: offset)
        case .invalidToken(let token, let index, _):
            return .invalidToken(token: token, index: index)
        case .unmatchedOpeningBracket(let offset): return .unmatchedOpeningBracket(offset: offset)
        case .unmatchedClosingBracket(let offset): return .unmatchedClosingBracket(offset: offset)
        case .inputTooLong(let limit): return .inputTooLong(limit: limit)
        case .tooManyLeaves(let limit): return .tooManyLeaves(limit: limit)
        case .nestingTooDeep(let limit): return .nestingTooDeep(limit: limit)
        case .timingOverflow: return .timingOverflow
        }
    }
}
