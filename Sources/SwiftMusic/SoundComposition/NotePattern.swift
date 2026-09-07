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

    private static func parse(_ value: String) throws -> [Pitch?] {
        let tokens = value.split(whereSeparator: Self.isASCIIWhitespace)
        guard !tokens.isEmpty else {
            throw NotePatternError.emptyInput
        }

        var parsed: [Pitch?] = []
        parsed.reserveCapacity(tokens.count)
        for (index, token) in tokens.enumerated() {
            if token == "~" {
                parsed.append(nil)
                continue
            }
            parsed.append(try pitch(from: token, index: index))
        }
        return parsed
    }

    private static func pitch(from token: Substring, index: Int) throws -> Pitch {
        let characters = Array(token)
        guard characters.count >= 2,
              let letter = characters[0].asciiValue else {
            throw NotePatternError.invalidToken(token: String(token), index: index)
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
            throw NotePatternError.invalidToken(token: String(token), index: index)
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
            throw NotePatternError.invalidToken(token: String(token), index: index)
        }

        var negative = false
        if characters[cursor] == "-" {
            negative = true
            cursor += 1
        }
        guard cursor < characters.count else {
            throw NotePatternError.invalidToken(token: String(token), index: index)
        }

        var octave = 0
        for character in characters[cursor...] {
            guard let ascii = character.asciiValue, (48...57).contains(ascii) else {
                throw NotePatternError.invalidToken(token: String(token), index: index)
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
            throw NotePatternError.pitchOutOfRange(token: String(token), index: index)
        }
    }

    private static func isASCIIWhitespace(_ character: Character) -> Bool {
        switch character.asciiValue {
        case 9, 10, 11, 12, 13, 32: true
        default: false
        }
    }
}
