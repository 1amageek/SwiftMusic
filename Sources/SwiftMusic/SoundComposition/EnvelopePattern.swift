/// A deferred bounded sequence of keyed amplitude envelopes.
public struct EnvelopePattern: Sendable, Equatable {
    private enum Storage: Sendable, Equatable {
        case notation(String, values: [String: Envelope])
        case typed([Envelope])
    }

    /// The source notation, or synthetic typed-value keys for an eager sequence.
    public let rawValue: String
    private let storage: Storage
    private let transform: _PatternTransform

    /// Creates and eagerly validates keyed envelope notation.
    public init(_ notation: String, values: [String: Envelope]) throws {
        guard !values.isEmpty else { throw EnvelopePatternError.emptyValueMap }
        guard values.count <= _MiniPatternParser.maximumLeaves else {
            throw EnvelopePatternError.tooManyTypedValues(limit: _MiniPatternParser.maximumLeaves)
        }
        _ = try Self.parseTimedProgram(notation, values: values)
        rawValue = notation
        storage = .notation(notation, values: values)
        transform = .identity
    }

    /// Creates and eagerly validates a flat typed envelope sequence.
    public init(steps: [Envelope]) throws {
        guard !steps.isEmpty else { throw EnvelopePatternError.emptyTypedValues }
        guard steps.count <= _MiniPatternParser.maximumLeaves else {
            throw EnvelopePatternError.tooManyTypedValues(limit: _MiniPatternParser.maximumLeaves)
        }
        rawValue = steps.indices.map { String($0) }.joined(separator: " ")
        storage = .typed(steps)
        transform = .identity
    }

    /// Resolves the pattern into typed envelopes in source order.
    public var steps: [Envelope] {
        get throws {
            try timedProgram.leaves.map { try value(at: $0) }
        }
    }

    /// Defers an integer phase-speed transformation until resolution.
    public func fast(_ factor: UInt64) -> Self {
        Self(rawValue: rawValue, storage: storage, transform: transform.fast(factor))
    }

    /// Defers an integer phase-slowing transformation until resolution.
    public func slow(_ factor: UInt64) -> Self {
        Self(rawValue: rawValue, storage: storage, transform: transform.slow(factor))
    }

    /// Defers a rational phase-speed transformation until resolution.
    public func fast(_ rate: PatternRate) -> Self {
        Self(rawValue: rawValue, storage: storage, transform: transform.fast(rate))
    }

    /// Defers a rational phase-slowing transformation until resolution.
    public func slow(_ rate: PatternRate) -> Self {
        Self(rawValue: rawValue, storage: storage, transform: transform.slow(rate))
    }

    /// Advances pattern sampling by an exact non-negative offset.
    public func phase(_ offset: MusicalTime) -> Self {
        Self(rawValue: rawValue, storage: storage, transform: transform.phase(offset))
    }

    /// Mirrors leaves within each local cycle while retaining source indices.
    public func reversed() -> Self {
        Self(rawValue: rawValue, storage: storage, transform: transform.reversed())
    }

    /// Fits successive local pattern cycles into one caller cycle.
    public func repeated(_ count: UInt64) -> Self {
        Self(rawValue: rawValue, storage: storage, transform: transform.repeated(count))
    }

    /// Resolves the source notation into its bounded natural-period program.
    internal var timedProgram: _PatternTimedProgram {
        get throws {
            switch storage {
            case .notation(let notation, let values):
                return try Self.parseTimedProgram(notation, values: values)
            case .typed(let values):
                return try Self.typedProgram(count: values.count)
            }
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
        } catch let error as EnvelopePatternError {
            throw error
        } catch let error as _PatternPhaseFailure {
            throw Self.map(error)
        } catch is MusicalTimeError {
            throw EnvelopePatternError.timingOverflow()
        }
    }

    /// Resolves one transformed leaf into its typed envelope value.
    internal func value(at leaf: _PatternTimedLeaf) throws -> Envelope {
        switch storage {
        case .notation(_, let values):
            guard let value = values[leaf.token] else {
                throw EnvelopePatternError.unknownKey(
                    token: leaf.token,
                    index: leaf.index,
                    offset: leaf.offset
                )
            }
            return value
        case .typed(let values):
            guard let index = Int(leaf.token), values.indices.contains(index) else {
                throw EnvelopePatternError.invalidToken(token: leaf.token, index: leaf.index, offset: leaf.offset)
            }
            return values[index]
        }
    }

    private init(rawValue: String, storage: Storage, transform: _PatternTransform) {
        self.rawValue = rawValue
        self.storage = storage
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

    private static func parseTimedProgram(
        _ notation: String,
        values: [String: Envelope]
    ) throws -> _PatternTimedProgram {
        do {
            var parser = try _MiniPatternParser(notation)
            let program = try parser.parse()
            for leaf in program.leaves {
                guard leaf.token != "~" else {
                    throw EnvelopePatternError.invalidToken(token: leaf.token, index: leaf.index, offset: leaf.offset)
                }
                guard values[leaf.token] != nil else {
                    throw EnvelopePatternError.unknownKey(token: leaf.token, index: leaf.index, offset: leaf.offset)
                }
            }
            return program
        } catch let error as EnvelopePatternError {
            throw error
        } catch let error as _PatternParserError {
            throw map(error)
        }
    }

    private static func map(_ error: _PatternParserError) -> EnvelopePatternError {
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

    private static func map(_ error: _PatternPhaseFailure) -> EnvelopePatternError {
        switch error {
        case .zeroFactor: return .zeroFactor
        case .invalidRate(let rate): return .invalidRate(rate)
        case .overflow: return .timingOverflow()
        }
    }
}
