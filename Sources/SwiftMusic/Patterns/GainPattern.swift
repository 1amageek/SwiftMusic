/// A deferred recursively subdivided sequence of per-event gain values.
public struct GainPattern: Sendable, Equatable, ExpressibleByStringLiteral {
    /// The source text retained by a literal or an eagerly validated value.
    public let rawValue: String
    private let transform: _PatternTransform

    /// Creates and eagerly validates a pattern from dynamic text.
    public init(_ value: String) throws {
        _ = try Self.parse(value)
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

    /// Resolves the source text into flat values for clients that need the legacy view.
    public var steps: [Double] {
        get throws { try Self.parse(rawValue) }
    }

    /// Defers a phase-speed transformation until the pattern is resolved.
    public func fast(_ factor: UInt64) -> Self {
        Self(rawValue: rawValue, transform: transform.fast(factor))
    }

    /// Defers a phase-slowing transformation until the pattern is resolved.
    public func slow(_ factor: UInt64) -> Self {
        Self(rawValue: rawValue, transform: transform.slow(factor))
    }

    /// Defers a rational phase-speed transformation until the pattern is resolved.
    public func fast(_ rate: PatternRate) -> Self {
        Self(rawValue: rawValue, transform: transform.fast(rate))
    }

    /// Defers a rational phase-slowing transformation until the pattern is resolved.
    public func slow(_ rate: PatternRate) -> Self {
        Self(rawValue: rawValue, transform: transform.slow(rate))
    }

    /// Advances pattern sampling by an exact non-negative offset.
    public func phase(_ offset: MusicalTime) -> Self {
        Self(rawValue: rawValue, transform: transform.phase(offset))
    }

    /// Mirrors leaves within each local cycle while retaining source indices.
    public func reversed() -> Self {
        Self(rawValue: rawValue, transform: transform.reversed())
    }

    /// Fits successive local pattern cycles into one caller cycle.
    public func repeated(_ count: UInt64) -> Self {
        Self(rawValue: rawValue, transform: transform.repeated(count))
    }

    /// Resolves the source text into its bounded natural-period program.
    internal var timedProgram: _PatternTimedProgram {
        get throws { try Self.parseTimedProgram(rawValue) }
    }

    /// Resolves the source text into exact recursive leaf timings for compilation.
    internal var timedLeaves: [_PatternTimedLeaf] {
        get throws { try timedProgram.leaves }
    }

    /// Resolves the source and its deferred domain transforms for the compiler.
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
        } catch let error as GainPatternError {
            throw error
        } catch let error as _PatternPhaseFailure {
            throw Self.map(error)
        } catch is MusicalTimeError {
            throw GainPatternError.timingOverflow()
        }
    }

    private init(rawValue: String, transform: _PatternTransform) {
        self.rawValue = rawValue
        self.transform = transform
    }

    private static func parse(_ value: String) throws -> [Double] {
        try parseTimedProgram(value).leaves.map { leaf in
            guard let gain = Double(leaf.token) else {
                throw GainPatternError.invalidToken(token: leaf.token, index: leaf.index, offset: leaf.offset)
            }
            return gain
        }
    }

    private static func parseTimedProgram(_ value: String) throws -> _PatternTimedProgram {
        var cache = _PatternParseCache()
        return try parseTimedProgram(value, cache: &cache)
    }

    private static func parseTimedProgram(_ value: String, cache: inout _PatternParseCache) throws -> _PatternTimedProgram {
        do {
            let program = try cache.parse(value)
            for leaf in program.leaves {
                guard leaf.token != "~" else {
                    throw GainPatternError.invalidToken(token: leaf.token, index: leaf.index, offset: leaf.offset)
                }
                guard let number = Double(leaf.token) else {
                    throw GainPatternError.invalidToken(token: leaf.token, index: leaf.index, offset: leaf.offset)
                }
                guard number.isFinite else {
                    throw GainPatternError.nonFiniteValue(token: leaf.token, index: leaf.index, offset: leaf.offset)
                }
                guard number >= 0 else {
                    throw GainPatternError.negativeValue(token: leaf.token, index: leaf.index, offset: leaf.offset)
                }
            }
            return program
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

    private static func map(_ error: _PatternPhaseFailure) -> GainPatternError {
        switch error {
        case .zeroFactor: return .zeroFactor
        case .invalidRate(let rate): return .invalidRate(rate)
        case .overflow: return .timingOverflow()
        }
    }
}
