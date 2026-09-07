import Testing
@testable import SwiftMusic

struct CyclePatternProgramTests {
    @Test(.timeLimit(.minutes(3)))
    func nestedAlternationUsesNaturalPeriodAndLexicalIndices() throws {
        var parser = try _MiniPatternParser("<a <b c>>")
        let program = try parser.parse()
        let expectedStarts: [MusicalTime] = [
            .zero,
            try MusicalTime(numerator: 1, denominator: 4),
            try MusicalTime(numerator: 1, denominator: 2),
            try MusicalTime(numerator: 3, denominator: 4)
        ]

        #expect(program.naturalPeriod == 4)
        #expect(program.leaves.map(\.token) == ["a", "b", "a", "c"])
        #expect(program.leaves.map(\.index) == [0, 1, 0, 2])
        #expect(program.leaves.map(\.start) == expectedStarts)
    }

    @Test(.timeLimit(.minutes(3)))
    func periodicSiblingUsesLCMWithoutIndependentFilling() throws {
        var parser = try _MiniPatternParser("<a b> c")
        let program = try parser.parse()
        let expectedDuration = try MusicalTime.quarter.divided(by: 4)

        #expect(program.naturalPeriod == 2)
        #expect(program.leaves.map(\.token) == ["a", "c", "b", "c"])
        #expect(program.leaves.map(\.duration) == Array(repeating: expectedDuration, count: 4))
    }

    @Test(.timeLimit(.minutes(3)))
    func repetitionOffsetsAndMalformedOperatorsAreLocated() throws {
        var parser = try _MiniPatternParser("x*3")
        let program = try parser.parse()
        #expect(program.leaves.count == 3)
        #expect(program.leaves.map(\.index) == [0, 0, 0])

        #expect {
            var parser = try _MiniPatternParser("x*2a")
            _ = try parser.parse()
        } throws: { error in
            error as? _PatternParserError == .invalidRepetition(token: "x*2a", index: 0, offset: 3)
        }
        #expect {
            var parser = try _MiniPatternParser("x**2")
            _ = try parser.parse()
        } throws: { error in
            error as? _PatternParserError == .invalidRepetition(token: "x**2", index: 0, offset: 2)
        }
        #expect {
            var parser = try _MiniPatternParser("é x*184467440737095516160")
            _ = try parser.parse()
        } throws: { error in
            error as? _PatternParserError == .invalidRepetition(
                token: "x*184467440737095516160",
                index: 1,
                offset: 24
            )
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func invalidHiddenBranchesAndRealizedPitchBoundsFailBeforeClientArrays() throws {
        let invalidGain: GainPattern = "<1 nope>"
        #expect {
            try invalidGain.steps
        } throws: { error in
            error as? GainPatternError == .invalidToken(token: "nope", index: 1, offset: 3)
        }

        let largeChord = String(repeating: "C4,E4 ", count: 513)
        #expect {
            try NotePattern(validating: largeChord)
        } throws: { error in
            guard case .tooManyLeaves(let limit, _) = error as? NotePatternError else {
                Issue.record("Expected the realized chord bound to fail")
                return false
            }
            return limit == _MiniPatternParser.maximumLeaves
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func naturalPeriodBoundIsCheckedBeforeFlattening() throws {
        var source = "x"
        for _ in 0..<11 {
            source = "<\(source) x>"
        }
        #expect {
            var parser = try _MiniPatternParser(source)
            _ = try parser.parse()
        } throws: { error in
            guard case .tooManyLeaves(let limit, let offset) = error as? _PatternParserError else {
                Issue.record("Expected the finite natural-period bound to fail")
                return false
            }
            return limit == _MiniPatternParser.maximumLeaves && offset == 0
        }
    }
}
