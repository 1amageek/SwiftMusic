/// A deferred recursively subdivided sequence of per-event gain values.
public struct GainPattern: Sendable, Equatable, ExpressibleByStringLiteral {
    /// The source text retained by a literal or an eagerly validated value.
    public let rawValue: String
    private let phase: _PatternPhaseScale

    /// Creates and eagerly validates a pattern from dynamic text.
    public init(_ value: String) throws {
        _ = try Self.parse(value)
        rawValue = value
        phase = .identity
    }

    /// Requests eager validation explicitly, including when the argument is a literal.
    public init(validating value: String) throws {
        try self.init(value)
    }

    /// Retains literal input without validating it during Swift source evaluation.
    public init(stringLiteral value: String) {
        rawValue = value
        phase = .identity
    }

    /// Resolves the source text into flat values for clients that need the legacy view.
    public var steps: [Double] {
        get throws {
            try Self.parse(rawValue)
        }
    }

    /// Defers a phase-speed transformation until the pattern is resolved.
    public func fast(_ factor: UInt64) -> Self {
        Self(rawValue: rawValue, phase: phase.fast(factor))
    }

    /// Defers a phase-slowing transformation until the pattern is resolved.
    public func slow(_ factor: UInt64) -> Self {
        Self(rawValue: rawValue, phase: phase.slow(factor))
    }

    /// Defers a rational phase-speed transformation until the pattern is resolved.
    public func fast(_ rate: PatternRate) -> Self {
        Self(rawValue: rawValue, phase: phase.fast(rate))
    }

    /// Defers a rational phase-slowing transformation until the pattern is resolved.
    public func slow(_ rate: PatternRate) -> Self {
        Self(rawValue: rawValue, phase: phase.slow(rate))
    }

    /// Resolves the source text into exact recursive leaf timings for compilation.
    internal var timedLeaves: [_PatternTimedLeaf] {
        get throws {
            try Self.parseTimedLeaves(rawValue)
        }
    }

    internal func resolvedCycle(from cycle: MusicalTime) throws -> MusicalTime {
        do {
            return try phase.resolvedCycle(from: cycle)
        } catch _PatternPhaseFailure.zeroFactor {
            throw GainPatternError.zeroFactor
        } catch _PatternPhaseFailure.invalidRate(let error) {
            throw GainPatternError.invalidRate(error)
        } catch _PatternPhaseFailure.overflow {
            throw GainPatternError.timingOverflow
        }
    }

    private init(rawValue: String, phase: _PatternPhaseScale) {
        self.rawValue = rawValue
        self.phase = phase
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
