/// A deferred bounded sequence of signed semitone offsets.
public struct PitchPattern: Sendable, Equatable, ExpressibleByStringLiteral {
    /// The source notation, or the canonical numeric representation of typed values.
    public let rawValue: String
    private let typedValues: [Semitones]?
    private let transform: _PatternTransform

    /// Creates and eagerly validates a pattern from dynamic notation.
    public init(_ value: String) throws {
        _ = try Self.parse(value)
        rawValue = value
        typedValues = nil
        transform = .identity
    }

    /// Requests eager validation explicitly, including when the argument is a literal.
    public init(validating value: String) throws {
        try self.init(value)
    }

    /// Creates and eagerly validates a pattern from typed semitone offsets.
    public init(steps: [Semitones]) throws {
        guard !steps.isEmpty else { throw PitchPatternError.emptyTypedValues }
        guard steps.count <= _MiniPatternParser.maximumLeaves else {
            throw PitchPatternError.tooManyTypedValues(limit: _MiniPatternParser.maximumLeaves)
        }
        rawValue = steps.map { String($0.value) }.joined(separator: " ")
        typedValues = steps
        transform = .identity
    }

    /// Retains literal input without validating it during Swift source evaluation.
    public init(stringLiteral value: String) {
        rawValue = value
        typedValues = nil
        transform = .identity
    }

    /// Resolves the pattern into typed semitone offsets in source order.
    public var steps: [Semitones] {
        get throws {
            try timedProgram.leaves.map { try value(at: $0) }
        }
    }

    /// Defers an integer phase-speed transformation until resolution.
    public func fast(_ factor: UInt64) -> Self {
        Self(rawValue: rawValue, typedValues: typedValues, transform: transform.fast(factor))
    }

    /// Defers an integer phase-slowing transformation until resolution.
    public func slow(_ factor: UInt64) -> Self {
        Self(rawValue: rawValue, typedValues: typedValues, transform: transform.slow(factor))
    }

    /// Defers a rational phase-speed transformation until resolution.
    public func fast(_ rate: PatternRate) -> Self {
        Self(rawValue: rawValue, typedValues: typedValues, transform: transform.fast(rate))
    }

    /// Defers a rational phase-slowing transformation until resolution.
    public func slow(_ rate: PatternRate) -> Self {
        Self(rawValue: rawValue, typedValues: typedValues, transform: transform.slow(rate))
    }

    /// Advances pattern sampling by an exact non-negative offset.
    public func phase(_ offset: MusicalTime) -> Self {
        Self(rawValue: rawValue, typedValues: typedValues, transform: transform.phase(offset))
    }

    /// Mirrors leaves within each local cycle while retaining source indices.
    public func reversed() -> Self {
        Self(rawValue: rawValue, typedValues: typedValues, transform: transform.reversed())
    }

    /// Fits successive local pattern cycles into one caller cycle.
    public func repeated(_ count: UInt64) -> Self {
        Self(rawValue: rawValue, typedValues: typedValues, transform: transform.repeated(count))
    }

    /// Resolves the source notation into its bounded natural-period program.
    internal var timedProgram: _PatternTimedProgram {
        get throws {
            var cache = _PatternParseCache()
            return try timedProgram(cache: &cache)
        }
    }

    private func timedProgram(cache: inout _PatternParseCache) throws -> _PatternTimedProgram {
        if let typedValues {
            return try Self.typedProgram(count: typedValues.count)
        }
        return try Self.parseTimedProgram(rawValue, cache: &cache)
    }

    /// Resolves the source notation into exact recursive leaf timings.
    internal var timedLeaves: [_PatternTimedLeaf] {
        get throws { try timedProgram.leaves }
    }

    /// Resolves source notation and deferred transforms for compiler consumers.
    internal func resolvedTransform(cycle: MusicalTime) throws -> _PatternResolvedTransform {
        var cache = _PatternParseCache()
        return try resolvedTransform(cycle: cycle, cache: &cache)
    }

    internal func resolvedTransform(cycle: MusicalTime, cache: inout _PatternParseCache) throws -> _PatternResolvedTransform {
        do {
            let result = try transform.resolve(
                try timedProgram(cache: &cache),
                cycle: cycle,
                splitWrappedLeaves: true
            )
            _ = try result.period
            return result
        } catch let error as PitchPatternError {
            throw error
        } catch let error as _PatternPhaseFailure {
            throw Self.map(error)
        } catch is MusicalTimeError {
            throw PitchPatternError.timingOverflow()
        }
    }

    /// Resolves one transformed leaf into its typed semitone value.
    internal func value(at leaf: _PatternTimedLeaf) throws -> Semitones {
        if let typedValues {
            guard let index = Int(leaf.token), typedValues.indices.contains(index) else {
                throw PitchPatternError.invalidToken(token: leaf.token, index: leaf.index, offset: leaf.offset)
            }
            return typedValues[index]
        }
        return try Self.value(token: leaf.token, index: leaf.index, offset: leaf.offset)
    }

    private init(rawValue: String, typedValues: [Semitones]?, transform: _PatternTransform) {
        self.rawValue = rawValue
        self.typedValues = typedValues
        self.transform = transform
    }

    private static func typedProgram(count: Int) throws -> _PatternTimedProgram {
        let denominator = UInt64(count)
        let duration = try MusicalTime(numerator: 1, denominator: denominator)
        let leaves = try (0..<count).map { index in
            _PatternTimedLeaf(
                token: String(index),
                index: index,
                offset: 0,
                start: try MusicalTime(numerator: UInt64(index), denominator: denominator),
                duration: duration
            )
        }
        return _PatternTimedProgram(naturalPeriod: 1, leaves: leaves)
    }

    private static func parse(_ value: String) throws -> [Semitones] {
        try parseTimedProgram(value).leaves.map { leaf in
            try Self.value(token: leaf.token, index: leaf.index, offset: leaf.offset)
        }
    }

    private static func value(token: String, index: Int, offset: Int) throws -> Semitones {
        guard let number = Double(token) else {
            throw PitchPatternError.invalidToken(token: token, index: index, offset: offset)
        }
        guard number.isFinite else {
            throw PitchPatternError.nonFiniteValue(token: token, index: index, offset: offset)
        }
        do {
            return try Semitones(value: number)
        } catch {
            throw PitchPatternError.nonFiniteValue(token: token, index: index, offset: offset)
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
                    throw PitchPatternError.invalidToken(token: leaf.token, index: leaf.index, offset: leaf.offset)
                }
                _ = try Self.value(token: leaf.token, index: leaf.index, offset: leaf.offset)
            }
            return program
        } catch let error as PitchPatternError {
            throw error
        } catch let error as _PatternParserError {
            throw map(error)
        }
    }

    private static func map(_ error: _PatternParserError) -> PitchPatternError {
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

    private static func map(_ error: _PatternPhaseFailure) -> PitchPatternError {
        switch error {
        case .zeroFactor: return .zeroFactor
        case .invalidRate(let rate): return .invalidRate(rate)
        case .overflow: return .timingOverflow()
        }
    }
}
