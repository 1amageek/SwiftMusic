/// A deferred sequence of scientific pitches and explicit rests.
public struct NotePattern: Sendable, Equatable, ExpressibleByStringLiteral {
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

    /// Resolves the source text for the compiler. A nil step is an explicit rest.
    public var steps: [Pitch?] {
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
        do {
            let result = try transform.resolve(try Self.parseTimedProgram(rawValue), cycle: cycle)
            _ = try result.period
            do {
                var remainingPitchBudget = _MiniPatternParser.maximumLeaves
                for leaf in result.program.leaves where leaf.token != "~" {
                    let pitches = try Self.pitches(from: leaf, maximumCount: remainingPitchBudget)
                    remainingPitchBudget -= pitches.count
                }
            } catch let error as NotePatternError {
                if case .tooManyLeaves = error {
                    throw NotePatternError.timingOverflow()
                }
                throw error
            }
            return result
        } catch let error as _PatternPhaseFailure {
            throw Self.map(error)
        } catch is MusicalTimeError {
            throw NotePatternError.timingOverflow()
        }
    }

    private static func parse(_ value: String) throws -> [Pitch?] {
        let program = try parseTimedProgram(value)
        var parsed: [Pitch?] = []
        parsed.reserveCapacity(program.leaves.count)
        for leaf in program.leaves {
            if leaf.token == "~" {
                parsed.append(nil)
            } else {
                parsed.append(contentsOf: try pitches(from: leaf))
            }
        }
        return parsed
    }

    private static func parseTimedProgram(_ value: String) throws -> _PatternTimedProgram {
        do {
            var parser = try _MiniPatternParser(value)
            let program = try parser.parse()
            var pitchCount = 0
            for leaf in program.leaves where leaf.token != "~" {
                let pitches = try pitches(from: leaf, maximumCount: _MiniPatternParser.maximumLeaves - pitchCount)
                pitchCount += pitches.count
            }
            return program
        } catch let error as NotePatternError {
            throw error
        } catch let error as _PatternParserError {
            throw map(error)
        }
    }

    internal static func pitches(
        from leaf: _PatternTimedLeaf,
        maximumCount: Int = _MiniPatternParser.maximumLeaves
    ) throws -> [Pitch] {
        let bytes = Array(leaf.token.utf8)
        var pitches: [Pitch] = []
        var memberStart = 0
        for position in 0...bytes.count {
            guard position == bytes.count || bytes[position] == 44 else { continue }
            guard position > memberStart else {
                throw NotePatternError.invalidToken(
                    token: leaf.token,
                    index: leaf.index,
                    offset: leaf.offset + memberStart
                )
            }
            guard pitches.count < maximumCount else {
                throw NotePatternError.tooManyLeaves(
                    limit: _MiniPatternParser.maximumLeaves,
                    offset: leaf.offset + memberStart
                )
            }
            let member = String(decoding: bytes[memberStart..<position], as: UTF8.self)
            pitches.append(try pitch(
                from: member,
                index: leaf.index,
                offset: leaf.offset + memberStart
            ))
            memberStart = position + 1
        }
        return pitches
    }

    internal static func pitch(from token: String, index: Int, offset: Int = 0) throws -> Pitch {
        let characters = Array(token)
        guard characters.count >= 2,
              let letter = characters[0].asciiValue else {
            throw NotePatternError.invalidToken(token: token, index: index, offset: offset)
        }

        let semitone: Int
        switch letter {
        case 65, 97: semitone = 9 // A / a
        case 66, 98: semitone = 11 // B / b
        case 67, 99: semitone = 0 // C / c
        case 68, 100: semitone = 2 // D / d
        case 69, 101: semitone = 4 // E / e
        case 70, 102: semitone = 5 // F / f
        case 71, 103: semitone = 7 // G / g
        default:
            throw NotePatternError.invalidToken(token: token, index: index, offset: offset)
        }

        var cursor = 1
        var accidental = 0
        if cursor < characters.count {
            switch characters[cursor] {
            case "#":
                accidental = 1
                cursor += 1
            case "b":
                accidental = -1
                cursor += 1
            default:
                break
            }
        }

        guard cursor < characters.count else {
            throw NotePatternError.invalidToken(token: token, index: index, offset: offset)
        }

        var negative = false
        if characters[cursor] == "-" {
            negative = true
            cursor += 1
        }
        guard cursor < characters.count else {
            throw NotePatternError.invalidToken(token: token, index: index, offset: offset)
        }

        var octave = 0
        for character in characters[cursor...] {
            guard let ascii = character.asciiValue, (48...57).contains(ascii) else {
                throw NotePatternError.invalidToken(token: token, index: index, offset: offset)
            }
            let digit = Int(ascii - 48)
            let (shifted, shiftOverflow) = octave.multipliedReportingOverflow(by: 10)
            let (next, addOverflow) = shifted.addingReportingOverflow(digit)
            guard !shiftOverflow, !addOverflow else {
                throw NotePatternError.pitchOutOfRange(token: token, index: index, offset: offset)
            }
            octave = next
        }
        if negative {
            octave = -octave
        }

        let (octaveOffset, octaveOverflow) = octave.addingReportingOverflow(1)
        let (base, multiplyOverflow) = octaveOffset.multipliedReportingOverflow(by: 12)
        let (midi, semitoneOverflow) = base.addingReportingOverflow(semitone + accidental)
        guard !octaveOverflow, !multiplyOverflow, !semitoneOverflow,
              (0...127).contains(midi) else {
            throw NotePatternError.pitchOutOfRange(token: token, index: index, offset: offset)
        }

        do {
            return try Pitch(midiNote: UInt8(midi))
        } catch {
            throw NotePatternError.pitchOutOfRange(token: token, index: index, offset: offset)
        }
    }

    private static func map(_ error: _PatternParserError) -> NotePatternError {
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

    private static func map(_ error: _PatternPhaseFailure) -> NotePatternError {
        switch error {
        case .zeroFactor: return .zeroFactor
        case .invalidRate(let rate): return .invalidRate(rate)
        case .overflow: return .timingOverflow()
        }
    }

    private init(rawValue: String, transform: _PatternTransform) {
        self.rawValue = rawValue
        self.transform = transform
    }
}
