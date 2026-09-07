/// A deferred recursively subdivided sequence of per-event pan values.
public struct PanPattern: Sendable, Equatable, ExpressibleByStringLiteral {
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

    /// Creates and eagerly validates a pattern from values in the pan domain.
    public init(steps: [Double]) throws {
        guard !steps.isEmpty else { throw PanPatternError.emptyInput }
        guard steps.count <= _MiniPatternParser.maximumLeaves else {
            throw PanPatternError.tooManyLeaves(limit: _MiniPatternParser.maximumLeaves, offset: 0)
        }
        for (index, value) in steps.enumerated() {
            guard value.isFinite else {
                throw PanPatternError.nonFiniteValue(token: String(value), index: index, offset: 0)
            }
            guard (-1...1).contains(value) else {
                throw PanPatternError.outOfRangeValue(token: String(value), index: index, offset: 0)
            }
        }
        rawValue = steps.map { String($0) }.joined(separator: " ")
        phase = .identity
    }

    /// Retains literal input without validating it during Swift source evaluation.
    public init(stringLiteral value: String) {
        rawValue = value
        phase = .identity
    }

    /// Resolves the source text into flat pan values.
    public var steps: [Double] {
        get throws { try Self.parse(rawValue) }
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

    /// Resolves the source text into its bounded natural-period program.
    internal var timedProgram: _PatternTimedProgram {
        get throws { try Self.parseTimedProgram(rawValue) }
    }

    /// Resolves the source text into exact recursive leaf timings for compilation.
    internal var timedLeaves: [_PatternTimedLeaf] {
        get throws { try timedProgram.leaves }
    }

    internal func resolvedCycle(from cycle: MusicalTime, naturalPeriod: Int = 1) throws -> MusicalTime {
        do {
            let transformed = try phase.resolvedCycle(from: cycle)
            return try transformed.multiplied(by: UInt64(naturalPeriod))
        } catch _PatternPhaseFailure.zeroFactor {
            throw PanPatternError.zeroFactor
        } catch _PatternPhaseFailure.invalidRate(let error) {
            throw PanPatternError.invalidRate(error)
        } catch _PatternPhaseFailure.overflow {
            throw PanPatternError.timingOverflow()
        } catch is MusicalTimeError {
            throw PanPatternError.timingOverflow()
        }
    }

    private init(rawValue: String, phase: _PatternPhaseScale) {
        self.rawValue = rawValue
        self.phase = phase
    }

    private static func parse(_ value: String) throws -> [Double] {
        try parseTimedProgram(value).leaves.map { leaf in
            guard let number = Double(leaf.token) else {
                throw PanPatternError.invalidToken(token: leaf.token, index: leaf.index, offset: leaf.offset)
            }
            return number
        }
    }

    private static func parseTimedProgram(_ value: String) throws -> _PatternTimedProgram {
        do {
            var parser = try _MiniPatternParser(value)
            let program = try parser.parse()
            for leaf in program.leaves {
                guard let number = Double(leaf.token) else {
                    throw PanPatternError.invalidToken(token: leaf.token, index: leaf.index, offset: leaf.offset)
                }
                guard number.isFinite else {
                    throw PanPatternError.nonFiniteValue(token: leaf.token, index: leaf.index, offset: leaf.offset)
                }
                guard (-1...1).contains(number) else {
                    throw PanPatternError.outOfRangeValue(token: leaf.token, index: leaf.index, offset: leaf.offset)
                }
            }
            return program
        } catch let error as PanPatternError {
            throw error
        } catch let error as _PatternParserError {
            throw map(error)
        }
    }

    private static func map(_ error: _PatternParserError) -> PanPatternError {
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
