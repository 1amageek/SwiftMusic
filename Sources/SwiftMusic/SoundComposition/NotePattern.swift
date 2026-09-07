/// A deferred sequence of scientific pitches and explicit rests.
public struct NotePattern: Sendable, Equatable, ExpressibleByStringLiteral {
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

    /// Resolves the source text for the compiler. A nil step is an explicit rest.
    public var steps: [Pitch?] {
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

    private static func parse(_ value: String) throws -> [Pitch?] {
        let leaves = try parseTimedLeaves(value)
        var parsed: [Pitch?] = []
        parsed.reserveCapacity(leaves.count)
        for leaf in leaves {
            if leaf.token == "~" {
                parsed.append(nil)
            } else {
                parsed.append(try pitch(from: leaf.token, index: leaf.index))
            }
        }
        return parsed
    }

    private static func parseTimedLeaves(_ value: String) throws -> [_PatternTimedLeaf] {
        do {
            var parser = try _MiniPatternParser(value)
            let leaves = try parser.parse()
            for leaf in leaves where leaf.token != "~" {
                _ = try pitch(from: leaf.token, index: leaf.index)
            }
            return leaves
        } catch let error as NotePatternError {
            throw error
        } catch let error as _PatternParserError {
            throw map(error)
        }
    }

    internal static func pitch(from token: String, index: Int) throws -> Pitch {
        let characters = Array(token)
        guard characters.count >= 2,
              let letter = characters[0].asciiValue else {
            throw NotePatternError.invalidToken(token: token, index: index)
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
            throw NotePatternError.invalidToken(token: token, index: index)
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
            throw NotePatternError.invalidToken(token: token, index: index)
        }

        var negative = false
        if characters[cursor] == "-" {
            negative = true
            cursor += 1
        }
        guard cursor < characters.count else {
            throw NotePatternError.invalidToken(token: token, index: index)
        }

        var octave = 0
        for character in characters[cursor...] {
            guard let ascii = character.asciiValue, (48...57).contains(ascii) else {
                throw NotePatternError.invalidToken(token: token, index: index)
            }
            let digit = Int(ascii - 48)
            let (shifted, shiftOverflow) = octave.multipliedReportingOverflow(by: 10)
            let (next, addOverflow) = shifted.addingReportingOverflow(digit)
            guard !shiftOverflow, !addOverflow else {
                throw NotePatternError.pitchOutOfRange(token: String(token), index: index)
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
            throw NotePatternError.pitchOutOfRange(token: String(token), index: index)
        }

        do {
            return try Pitch(midiNote: UInt8(midi))
        } catch {
            throw NotePatternError.pitchOutOfRange(token: token, index: index)
        }
    }

    private static func map(_ error: _PatternParserError) -> NotePatternError {
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
