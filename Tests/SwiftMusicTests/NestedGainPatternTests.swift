import SwiftMusic
import XCTest

final class NestedGainPatternTests: XCTestCase {
    func testNestedRhythmUsesExactLeafDurationsAndIndices() throws {
        let compiled = try SoundCompiler().compile(
            Sample("kick").rhythm("[x ~] x", cycle: .whole)
        )

        XCTAssertEqual(compiled.events.map(\.start), [.zero, .half])
        XCTAssertEqual(compiled.events.map(\.duration), [.quarter, .half])
        XCTAssertEqual(compiled.events.map(\.patternStepIndex), [0, 2])
        XCTAssertEqual(compiled.sources[0].patternText, "[x ~] x")
    }

    func testNestedNotesPreserveRestsAndUseDepthFirstIndices() throws {
        let compiled = try SoundCompiler().compile(
            Synthesizer(.sine).notes("[C4 ~] [D4 E4]", cycle: .whole)
        )

        XCTAssertEqual(compiled.events.map(\.start), [.zero, .half, try .half.adding(.quarter)])
        XCTAssertEqual(compiled.events.map(\.duration), Array(repeating: .quarter, count: 3))
        XCTAssertEqual(compiled.events.map { $0.pitch?.midiNote }, [60, 62, 64])
        XCTAssertEqual(compiled.events.map(\.patternStepIndex), [0, 2, 3])
    }

    func testNestedSyntaxFailuresAndBoundsAreTyped() throws {
        let emptyGroup: RhythmPattern = "[]"
        XCTAssertThrowsError(try SoundCompiler().compile(Sample("kick").rhythm(emptyGroup))) {
            XCTAssertEqual(
                $0 as? SoundCompilationError,
                .invalidRhythm(.emptyGroup(offset: 0))
            )
        }

        let unmatched: RhythmPattern = "[x"
        XCTAssertThrowsError(try SoundCompiler().compile(Sample("kick").rhythm(unmatched))) {
            XCTAssertEqual(
                $0 as? SoundCompilationError,
                .invalidRhythm(.unmatchedOpeningBracket(offset: 0))
            )
        }

        let tooDeep = RhythmPattern(stringLiteral: String(repeating: "[", count: 33) + "x")
        XCTAssertThrowsError(try SoundCompiler().compile(Sample("kick").rhythm(tooDeep))) {
            XCTAssertEqual(
                $0 as? SoundCompilationError,
                .invalidRhythm(.nestingTooDeep(limit: 32))
            )
        }

        let tooManyLeaves = RhythmPattern(stringLiteral: String(repeating: "x ", count: 1_025))
        XCTAssertThrowsError(try SoundCompiler().compile(Sample("kick").rhythm(tooManyLeaves))) {
            XCTAssertEqual(
                $0 as? SoundCompilationError,
                .invalidRhythm(.tooManyLeaves(limit: 1_024))
            )
        }

        let tooLong = RhythmPattern(stringLiteral: String(repeating: "x", count: 65 * 1024 + 1))
        XCTAssertThrowsError(try SoundCompiler().compile(Sample("kick").rhythm(tooLong))) {
            XCTAssertEqual(
                $0 as? SoundCompilationError,
                .invalidRhythm(.inputTooLong(limit: 64 * 1024))
            )
        }

        XCTAssertThrowsError(
            try RhythmPattern(steps: Array(repeating: true, count: 1_025))
        ) {
            XCTAssertEqual(
                $0 as? RhythmPatternError,
                .tooManyLeaves(limit: 1_024)
            )
        }
    }

    func testGainPatternSamplesExactCycleBoundariesAndStacks() throws {
        let repeated = try SoundCompiler().compile(
            Sample("kick")
                .rhythm("x x x x", cycle: .whole)
                .gain("[1 0.5]")
        )
        XCTAssertEqual(repeated.events.map(\.gain), [1, 1, 0.5, 0.5])

        let stacked = try SoundCompiler().compile(
            Sample("kick")
                .rhythm("x x", cycle: .whole)
                .gain("2 0.5")
                .gain("0.5 2")
        )
        XCTAssertEqual(stacked.events.map(\.gain), [1, 1])

        let transformedAfterGain = try SoundCompiler().compile(
            Sample("kick")
                .rhythm("x x", cycle: .whole)
                .gain("1 2")
                .fast(2)
        )
        XCTAssertEqual(transformedAfterGain.events.map(\.gain), [1, 2])

        let transformedBeforeGain = try SoundCompiler().compile(
            Sample("kick")
                .rhythm("x x", cycle: .whole)
                .fast(2)
                .gain("1 2")
        )
        XCTAssertEqual(transformedBeforeGain.events.map(\.gain), [1, 1])
    }

    func testGainPatternRepeatsAcrossCyclesWithUnequalEventCount() throws {
        let compiled = try SoundCompiler().compile(
            Sample("kick")
                .rhythm("x x", cycle: .whole)
                .repeated(3)
                .gain("[1 0.5 0.25]")
        )

        XCTAssertEqual(compiled.events.map(\.start), [
            .zero, .half, .whole,
            try .whole.adding(.half), try .whole.adding(.whole),
            try .whole.adding(.whole).adding(.half)
        ])
        XCTAssertEqual(compiled.events.map(\.gain), [1, 0.5, 1, 0.5, 1, 0.5])
    }

    func testGainPatternAllowsZeroAndRejectsInvalidOrNonfiniteValues() throws {
        let silent = try SoundCompiler().compile(
            Sample("kick").rhythm("x x", cycle: .whole).gain("0 1")
        )
        XCTAssertEqual(silent.events.map(\.gain), [0, 1])

        let invalidRest: GainPattern = "1 ~"
        XCTAssertThrowsError(try SoundCompiler().compile(Sample("kick").gain(invalidRest))) {
            XCTAssertEqual(
                $0 as? SoundCompilationError,
                .invalidGainPattern(.invalidToken(token: "~", index: 1))
            )
        }

        let negative: GainPattern = "-1"
        XCTAssertThrowsError(try SoundCompiler().compile(Sample("kick").gain(negative))) {
            XCTAssertEqual(
                $0 as? SoundCompilationError,
                .invalidGainPattern(.negativeValue(token: "-1", index: 0))
            )
        }

        let nonfinite: GainPattern = "nan"
        XCTAssertThrowsError(try SoundCompiler().compile(Sample("kick").gain(nonfinite))) {
            XCTAssertEqual(
                $0 as? SoundCompilationError,
                .invalidGainPattern(.nonFiniteValue(token: "nan", index: 0))
            )
        }

        let overflow: GainPattern = "1e308"
        XCTAssertThrowsError(
            try SoundCompiler().compile(Sample("kick").gain(overflow).gain(overflow))
        ) {
            guard case .invalidParameter = $0 as? SoundCompilationError else {
                return XCTFail("Expected a finite stacked gain product")
            }
        }

        let scalar = try SoundCompiler().compile(Sample("kick").gain(0.5))
        XCTAssertEqual(scalar.events.map(\.gain), [1])
        XCTAssertEqual(scalar.renderNodes, [.source(sourceID: 0), .gain(input: 0, value: 0.5)])
    }
}
