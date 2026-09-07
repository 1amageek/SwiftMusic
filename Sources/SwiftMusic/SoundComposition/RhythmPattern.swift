/// A deferred sequence of hit (`x`) and rest (`~`) steps.
public struct RhythmPattern: Sendable, Equatable, ExpressibleByStringLiteral {
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

    /// Creates and eagerly validates a pattern from explicit steps.
    public init(steps: [Bool]) throws {
        guard !steps.isEmpty else {
            throw RhythmPatternError.emptyInput
        }
        rawValue = steps.map { $0 ? "x" : "~" }.joined(separator: " ")
    }

    /// Retains literal input without validating it during Swift source evaluation.
    public init(stringLiteral value: String) {
        rawValue = value
    }

    /// Resolves the source text for the compiler.
    public var steps: [Bool] {
        get throws {
            try Self.parse(rawValue)
        }
    }

    private static func parse(_ value: String) throws -> [Bool] {
        let tokens = value.split(whereSeparator: Self.isASCIIWhitespace)
        guard !tokens.isEmpty else {
            throw RhythmPatternError.emptyInput
        }

        var parsed: [Bool] = []
        parsed.reserveCapacity(tokens.count)
        for (index, token) in tokens.enumerated() {
            switch token {
            case "x": parsed.append(true)
            case "~": parsed.append(false)
            default:
                throw RhythmPatternError.invalidToken(token: String(token), index: index)
            }
        }
        return parsed
    }

    private static func isASCIIWhitespace(_ character: Character) -> Bool {
        switch character.asciiValue {
        case 9, 10, 11, 12, 13, 32: true
        default: false
        }
    }
}
