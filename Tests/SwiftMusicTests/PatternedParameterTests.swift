import XCTest
@testable import SwiftMusic

final class PatternedParameterTests: XCTestCase {
    func testGainPatternIntegerFastAndSlowAreDeferredAndExact() throws {
        let fastPattern = try GainPattern(validating: "1 2").fast(2)
        let fast = try SoundCompiler().compile(
            Sample("kick")
                .rhythm("x x x x", cycle: .whole)
                .gain(fastPattern)
        )
        XCTAssertEqual(fast.events.map(\.gain), [1, 2, 1, 2])

        let slowPattern = try GainPattern(validating: "1 2").slow(2)
        let slow = try SoundCompiler().compile(
            Sample("kick")
                .rhythm("x x x x", cycle: .whole)
                .repeated(2)
                .gain(slowPattern)
        )
        XCTAssertEqual(slow.events.map(\.gain), [1, 1, 1, 1, 2, 2, 2, 2])

        let zeroFactor: GainPattern = "1"
        XCTAssertThrowsError(
            try SoundCompiler().compile(Sample("kick").gain(zeroFactor.fast(0)))
        ) { error in
            XCTAssertEqual(error as? SoundCompilationError, .invalidGainPattern(.zeroFactor))
        }

        let overflowing: GainPattern = "1"
        XCTAssertThrowsError(
            try SoundCompiler().compile(
                Sample("kick").gain(overflowing.slow(UInt64.max).slow(2))
            )
        ) { error in
            XCTAssertEqual(error as? SoundCompilationError, .invalidGainPattern(.timingOverflow))
        }
    }

    func testPanPatternSamplesAtOnsetsAndOuterPatternWins() throws {
        let first: PanPattern = "-1 1"
        let second: PanPattern = "0 1"
        let sound = Synthesizer(.sine)
            .rhythm("x x", cycle: .whole)
            .pan(first)
            .pan(second)
        let compiled = try SoundCompiler().compile(sound)

        XCTAssertEqual(compiled.events.map(\.pan), [0, 1])
    }

    func testPanPatternSamplesAfterTimeTransformAndPreservesEarlierAssignment() throws {
        let pattern: PanPattern = "-1 1"
        let sampledAfterTime = try SoundCompiler().compile(
            Synthesizer(.sine)
                .rhythm("x x x x", cycle: .whole)
                .fast(2)
                .pan(pattern)
        )
        XCTAssertEqual(sampledAfterTime.events.map(\.pan), [-1, -1, -1, -1])

        let assignedBeforeTime = try SoundCompiler().compile(
            Synthesizer(.sine)
                .rhythm("x x", cycle: .whole)
                .pan(pattern)
                .fast(2)
        )
        XCTAssertEqual(assignedBeforeTime.events.map(\.pan), [-1, 1])
        XCTAssertEqual(assignedBeforeTime.events.map(\.start), [.zero, .quarter])
    }

    func testPanPatternIntegerFastAndSlowResolveAtExactOnsets() throws {
        let pattern: PanPattern = "-1 1"
        let fast = try SoundCompiler().compile(
            Synthesizer(.sine)
                .rhythm("x x x x", cycle: .whole)
                .pan(pattern.fast(2))
        )
        XCTAssertEqual(fast.events.map(\.pan), [-1, 1, -1, 1])

        let slow = try SoundCompiler().compile(
            Synthesizer(.sine)
                .rhythm("x x x x", cycle: .whole)
                .repeated(2)
                .pan(pattern.slow(2))
        )
        XCTAssertEqual(slow.events.map(\.pan), [-1, -1, -1, -1, 1, 1, 1, 1])
    }

    func testPanPatternDefersLiteralValidationAndRejectsDomainFailures() throws {
        XCTAssertThrowsError(try PanPattern(validating: "")) { error in
            XCTAssertEqual(error as? PanPatternError, .emptyInput)
        }
        XCTAssertThrowsError(try PanPattern(steps: [])) { error in
            XCTAssertEqual(error as? PanPatternError, .emptyInput)
        }

        let outOfRange: PanPattern = "1.5"
        XCTAssertThrowsError(
            try SoundCompiler().compile(Synthesizer(.sine).pan(outOfRange))
        ) { error in
            XCTAssertEqual(
                error as? SoundCompilationError,
                .invalidPanPattern(.outOfRangeValue(token: "1.5", index: 0))
            )
        }

        let nonFinite: PanPattern = "nan"
        XCTAssertThrowsError(
            try SoundCompiler().compile(Synthesizer(.sine).pan(nonFinite))
        ) { error in
            XCTAssertEqual(
                error as? SoundCompilationError,
                .invalidPanPattern(.nonFiniteValue(token: "nan", index: 0))
            )
        }

        let zeroFactor: PanPattern = "0 1"
        XCTAssertThrowsError(
            try SoundCompiler().compile(Synthesizer(.sine).pan(zeroFactor.fast(0)))
        ) { error in
            XCTAssertEqual(error as? SoundCompilationError, .invalidPanPattern(.zeroFactor))
        }

        let overflowing: PanPattern = "0 1"
        XCTAssertThrowsError(
            try SoundCompiler().compile(Synthesizer(.sine).pan(overflowing.slow(UInt64.max).slow(2)))
        ) { error in
            XCTAssertEqual(error as? SoundCompilationError, .invalidPanPattern(.timingOverflow))
        }
    }

    func testPanPatternPreservesNilMetadataForUnmodifiedEvents() throws {
        let plain = try SoundCompiler().compile(Synthesizer(.sine))
        XCTAssertEqual(plain.events.map(\.pan), [nil])

        let explicitCenter = try SoundCompiler().compile(
            Synthesizer(.sine).pan(try PanPattern(validating: "0"))
        )
        XCTAssertEqual(explicitCenter.events.map(\.pan), [0])
    }
}
