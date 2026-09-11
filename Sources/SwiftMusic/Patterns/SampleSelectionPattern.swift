/// A bounded pattern of sample-bank keys evaluated at event onsets.
public struct SampleSelectionPattern: Sendable, Equatable, ExpressibleByStringLiteral {
    public let rawValue: String
    private let transform: _PatternTransform

    /// Creates and eagerly validates a pattern from dynamic text.
    public init(_ value: String) throws {
        _ = try Self.parseTimedProgram(value)
        rawValue = value
        transform = .identity
    }

    /// Requests eager validation explicitly, including when the argument is a literal.
    public init(validating value: String) throws {
        try self.init(value)
    }

    /// Retains literal input without validating it during Swift source evaluation.
    public init(stringLiteral value: String) {
        rawValue = value
        transform = .identity
    }

    /// Resolves the source text into flat bank keys.
    public var steps: [String] {
        get throws { try Self.parseTimedProgram(rawValue).leaves.map(\.token) }
    }

    public func fast(_ factor: UInt64) -> Self {
        Self(rawValue: rawValue, transform: transform.fast(factor))
    }

    public func slow(_ factor: UInt64) -> Self {
        Self(rawValue: rawValue, transform: transform.slow(factor))
    }

    public func fast(_ rate: PatternRate) -> Self {
        Self(rawValue: rawValue, transform: transform.fast(rate))
    }

    public func slow(_ rate: PatternRate) -> Self {
        Self(rawValue: rawValue, transform: transform.slow(rate))
    }

    public func phase(_ offset: MusicalTime) -> Self {
        Self(rawValue: rawValue, transform: transform.phase(offset))
    }

    public func reversed() -> Self {
        Self(rawValue: rawValue, transform: transform.reversed())
    }

    public func repeated(_ count: UInt64) -> Self {
        Self(rawValue: rawValue, transform: transform.repeated(count))
    }

    internal func resolvedTransform(cycle: MusicalTime) throws -> _PatternResolvedTransform {
        var cache = _PatternParseCache()
        return try resolvedTransform(cycle: cycle, cache: &cache)
    }

    internal func resolvedTransform(cycle: MusicalTime, cache: inout _PatternParseCache) throws -> _PatternResolvedTransform {
        do {
            let result = try transform.resolve(
                try Self.parseTimedProgram(rawValue, cache: &cache),
                cycle: cycle,
                splitWrappedLeaves: true
            )
            _ = try result.period
            return result
        } catch let error as SampleSelectionPatternError {
            throw error
        } catch let error as _PatternPhaseFailure {
            throw Self.map(error)
        } catch is MusicalTimeError {
            throw SampleSelectionPatternError.timingOverflow()
        }
    }

    internal func value(at leaf: _PatternTimedLeaf) throws -> String {
        guard leaf.token != "~" else {
            throw SampleSelectionPatternError.invalidToken(
                token: leaf.token, index: leaf.index, offset: leaf.offset
            )
        }
        return leaf.token
    }

    private init(rawValue: String, transform: _PatternTransform) {
        self.rawValue = rawValue
        self.transform = transform
    }

    private static func parseTimedProgram(_ value: String) throws -> _PatternTimedProgram {
        var cache = _PatternParseCache()
        return try parseTimedProgram(value, cache: &cache)
    }

    private static func parseTimedProgram(_ value: String, cache: inout _PatternParseCache) throws -> _PatternTimedProgram {
        do {
            let program = try cache.parse(value)
            for leaf in program.leaves where leaf.token == "~" {
                throw SampleSelectionPatternError.invalidToken(
                    token: leaf.token, index: leaf.index, offset: leaf.offset
                )
            }
            return program
        } catch let error as SampleSelectionPatternError {
            throw error
        } catch let error as _PatternParserError {
            throw map(error)
        }
    }

    private static func map(_ error: _PatternParserError) -> SampleSelectionPatternError {
        switch error {
        case .emptyInput: return .emptyInput
        case .emptyGroup(let offset): return .emptyGroup(offset: offset)
        case .invalidToken(let token, let index, let offset):
            return .invalidToken(token: token, index: index, offset: offset)
        case .invalidRepetition(let token, let index, let offset):
            return .invalidRepetition(token: token, index: index, offset: offset)
        case .unmatchedOpeningBracket(let offset): return .unmatchedOpeningBracket(offset: offset)
        case .unmatchedClosingBracket(let offset): return .unmatchedClosingBracket(offset: offset)
        case .unmatchedOpeningAngleBracket(let offset):
            return .unmatchedOpeningAngleBracket(offset: offset)
        case .unmatchedClosingAngleBracket(let offset):
            return .unmatchedClosingAngleBracket(offset: offset)
        case .inputTooLong(let limit, let offset): return .inputTooLong(limit: limit, offset: offset)
        case .tooManyLeaves(let limit, let offset): return .tooManyLeaves(limit: limit, offset: offset)
        case .nestingTooDeep(let limit, let offset): return .nestingTooDeep(limit: limit, offset: offset)
        case .timingOverflow(let offset): return .timingOverflow(offset: offset)
        }
    }

    private static func map(_ error: _PatternPhaseFailure) -> SampleSelectionPatternError {
        switch error {
        case .zeroFactor: return .zeroFactor
        case .invalidRate(let rate): return .invalidRate(rate)
        case .overflow: return .timingOverflow()
        }
    }
}
