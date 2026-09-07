import SwiftMusic
import Testing

struct CyclePatternCompilationTests {
    @Test(.timeLimit(.minutes(3)))
    func cycleArithmeticFailureRetainsItsPatternDomainWithoutSourceOffset() throws {
        let cycle = try MusicalTime(numerator: UInt64.max, denominator: 1)
        #expect {
            try SoundCompiler().compile(Sample("kick").rhythm("<x x>", cycle: cycle))
        } throws: { error in
            error as? SoundCompilationError == .invalidRhythm(.timingOverflow())
        }
        #expect {
            try SoundCompiler().compile(Synthesizer(.sine).notes("<C4 E4>", cycle: cycle))
        } throws: { error in
            error as? SoundCompilationError == .invalidNotes(.timingOverflow())
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func numericAlternativesAdvanceAtAbsoluteOnsetsWithFractionalRates() throws {
        let gain: GainPattern = "<1 0.5>"
        let pan: PanPattern = "<-1 1>"
        let sound = Sample("kick").rhythm("x").repeated(4)
        let compiled = try SoundCompiler().compile(sound.gain(gain.fast(1.5)).pan(pan))
        #expect(compiled.events.map(\.start) == [.zero, .whole, try MusicalTime(numerator: 8, denominator: 1), try MusicalTime(numerator: 12, denominator: 1)])
        #expect(compiled.events.map(\.gain) == [1, 0.5, 0.5, 1])
        #expect(compiled.events.map(\.pan) == [-1, 1, -1, 1])
    }

    @Test(.timeLimit(.minutes(3)))
    func nestedAlternationPreservesSilentCyclesAndLexicalIdentity() throws {
        let compiled = try SoundCompiler().compile(Sample("kick").rhythm("<x <~ x>>"))
        #expect(compiled.extent == (try MusicalTime(numerator: 16, denominator: 1)))
        #expect(compiled.events.map(\.start) == [.zero, try MusicalTime(numerator: 8, denominator: 1), try MusicalTime(numerator: 12, denominator: 1)])
        #expect(compiled.events.map(\.patternStepIndex) == [0, 0, 2])
        let silent = try SoundCompiler().compile(Sample("kick").rhythm("<~ ~>"))
        #expect(silent.events.isEmpty)
        #expect(silent.extent == (try MusicalTime(numerator: 8, denominator: 1)))
    }

    @Test(.timeLimit(.minutes(3)))
    func repeatedChordChecksCompilerEventLimitBeforeExpansion() throws {
        let compiler = SoundCompiler(limits: try .init(maximumEvents: 5))
        #expect {
            try compiler.compile(Synthesizer(.sine).notes("C4,E4*3"))
        } throws: { error in
            error as? SoundCompilationError == .maximumEventsExceeded(limit: 5)
        }
        let oversizedChord = Array(repeating: "C4", count: 1_025).joined(separator: ",")
        #expect {
            try NotePattern(validating: oversizedChord)
        } throws: { error in
            error as? NotePatternError == .tooManyLeaves(limit: 1_024, offset: 3_072)
        }
        let aggregateOverflow = String(repeating: "C4 ", count: 1_023) + "D4,E4"
        #expect {
            try NotePattern(validating: aggregateOverflow)
        } throws: { error in
            error as? NotePatternError == .tooManyLeaves(limit: 1_024, offset: 3_072)
        }
    }
}
