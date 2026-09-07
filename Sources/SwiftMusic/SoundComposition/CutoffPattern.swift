/// A deferred bounded sequence of positive low-pass cutoff frequencies.
public struct CutoffPattern: Sendable, Equatable, ExpressibleByStringLiteral {
    /// The source notation, or the canonical numeric representation of typed values.
    public let rawValue: String
    private let typedValues: [Frequency]?
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

    /// Creates and eagerly validates a pattern from typed cutoff frequencies.
    public init(steps: [Frequency]) throws {
        guard !steps.isEmpty else { throw CutoffPatternError.emptyTypedValues }
        guard steps.count <= _MiniPatternParser.maximumLeaves else {
            throw CutoffPatternError.tooManyTypedValues(limit: _MiniPatternParser.maximumLeaves)
        }
        rawValue = steps.map { String($0.hertz) }.joined(separator: " ")
        typedValues = steps
        transform = .identity
    }

    /// Retains literal input without validating it during Swift source evaluation.
    public init(stringLiteral value: String) {
        rawValue = value
        typedValues = nil
        transform = .identity
    }

    /// Resolves the pattern into typed cutoff frequencies in source order.
    public var steps: [Frequency] {
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
            if let typedValues {
                return try Self.typedProgram(count: typedValues.count)
            }
            return try Self.parseTimedProgram(rawValue)
        }
    }

    /// Resolves the source notation into exact recursive leaf timings.
    internal var timedLeaves: [_PatternTimedLeaf] {
        get throws { try timedProgram.leaves }
    }

    /// Resolves source notation and deferred transforms for compiler consumers.
    internal func resolvedTransform(cycle: MusicalTime) throws -> _PatternResolvedTransform {
        do {
            let result = try transform.resolve(
                try timedProgram,
                cycle: cycle,
                splitWrappedLeaves: true
            )
            _ = try result.period
            return result
        } catch let error as CutoffPatternError {
            throw error
        } catch let error as _PatternPhaseFailure {
            throw Self.map(error)
        } catch is MusicalTimeError {
            throw CutoffPatternError.timingOverflow()
        }
    }

    /// Resolves one transformed leaf into its typed cutoff value.
    internal func value(at leaf: _PatternTimedLeaf) throws -> Frequency {
        if let typedValues {
            guard let index = Int(leaf.token), typedValues.indices.contains(index) else {
                throw CutoffPatternError.invalidToken(token: leaf.token, index: leaf.index, offset: leaf.offset)
            }
            return typedValues[index]
        }
        return try Self.value(token: leaf.token, index: leaf.index, offset: leaf.offset)
    }

    private init(rawValue: String, typedValues: [Frequency]?, transform: _PatternTransform) {
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

    private static func parse(_ value: String) throws -> [Frequency] {
        try parseTimedProgram(value).leaves.map { leaf in
            try Self.value(token: leaf.token, index: leaf.index, offset: leaf.offset)
        }
    }

    private static func value(token: String, index: Int, offset: Int) throws -> Frequency {
        guard let number = Double(token) else {
            throw CutoffPatternError.invalidToken(token: token, index: index, offset: offset)
        }
        guard number.isFinite else {
            throw CutoffPatternError.nonFiniteValue(token: token, index: index, offset: offset)
        }
        guard number > 0 else {
            throw CutoffPatternError.nonPositiveValue(token: token, index: index, offset: offset)
        }
        do {
            return try Frequency(hertz: number)
        } catch {
            throw CutoffPatternError.nonPositiveValue(token: token, index: index, offset: offset)
        }
    }

    private static func parseTimedProgram(_ value: String) throws -> _PatternTimedProgram {
        do {
            var parser = try _MiniPatternParser(value)
            let program = try parser.parse()
            for leaf in program.leaves {
                guard leaf.token != "~" else {
                    throw CutoffPatternError.invalidToken(token: leaf.token, index: leaf.index, offset: leaf.offset)
                }
                _ = try Self.value(token: leaf.token, index: leaf.index, offset: leaf.offset)
            }
            return program
        } catch let error as CutoffPatternError {
            throw error
        } catch let error as _PatternParserError {
            throw map(error)
        }
    }

    private static func map(_ error: _PatternParserError) -> CutoffPatternError {
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

    private static func map(_ error: _PatternPhaseFailure) -> CutoffPatternError {
        switch error {
        case .zeroFactor: return .zeroFactor
        case .invalidRate(let rate): return .invalidRate(rate)
        case .overflow: return .timingOverflow()
        }
    }
}
