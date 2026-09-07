/// A bounded sequence of hit (`x`) and rest (`~`) steps.
public struct RhythmPattern: Sendable, Equatable {
    public let steps: [Bool]

    public init(_ value: String) throws {
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
        steps = parsed
    }

    public init(steps: [Bool]) throws {
        guard !steps.isEmpty else {
            throw RhythmPatternError.emptyInput
        }
        self.steps = steps
    }

    private static func isASCIIWhitespace(_ character: Character) -> Bool {
        switch character.asciiValue {
        case 9, 10, 11, 12, 13, 32: true
        default: false
        }
    }
}
