import XCTest
import SwiftMusic

final class SwiftMusicTests: XCTestCase {
    private func pitch(_ midiNote: UInt8) -> Pitch {
        try! Pitch(midiNote: midiNote)
    }

    func testMusicAndCustomScoreCompileThroughPublicDeclaration() throws {
        struct Fragment: Score {
            var body: some Score {
                Note(pitch: try! Pitch(midiNote: 60), start: .zero, duration: .quarter)
            }
        }

        struct Song: Music {
            var score: some Score {
                Fragment()
            }
        }

        let compiled = try ScoreCompiler().compile(Song())

        XCTAssertEqual(compiled.events.count, 1)
        XCTAssertEqual(compiled.events[0].pitch, pitch(60))
        XCTAssertEqual(compiled.events[0].start, .zero)
        XCTAssertEqual(compiled.events[0].duration, .quarter)
    }

    func testBuilderSiblingsAreParallelAndControlFlowIsSupported() throws {
        struct BranchingScore: Score {
            let enabled: Bool
            let includeOptional: Bool

            var body: some Score {
                if enabled {
                    Note(pitch: try! Pitch(midiNote: 60), start: .zero, duration: .quarter)
                } else {
                    Note(pitch: try! Pitch(midiNote: 61), start: .zero, duration: .quarter)
                }

                if includeOptional {
                    Note(pitch: try! Pitch(midiNote: 62), start: .quarter, duration: .quarter)
                }

                for index in 0..<2 {
                    Note(
                        pitch: try! Pitch(midiNote: UInt8(64 + index)),
                        start: try! MusicalTime(numerator: UInt64(index * 2), denominator: 1),
                        duration: .quarter
                    )
                }
            }
        }

        let compiled = try ScoreCompiler().compile(
            BranchingScore(enabled: true, includeOptional: false)
        )

        XCTAssertEqual(compiled.events.map(\.pitch.midiNote), [60, 64, 65])
        XCTAssertEqual(compiled.events.map(\.start), [.zero, .zero, .half])
        XCTAssertEqual(compiled.extent, try .half.adding(.quarter))

        let alternate = try ScoreCompiler().compile(
            BranchingScore(enabled: false, includeOptional: true)
        )
        XCTAssertEqual(alternate.events.map(\.pitch.midiNote), [61, 64, 62, 65])
        XCTAssertEqual(alternate.events.map(\.start), [.zero, .zero, .quarter, .half])
    }

    func testTrackMetadataNestingAndTiming() throws {
        struct GroupedScore: Score {
            var body: some Score {
                Track("outer") {
                    Track("inner") {
                        Note(pitch: try! Pitch(midiNote: 36), start: .half, duration: .quarter)
                    }
                }

                Track("empty") {}
            }
        }

        let compiled = try ScoreCompiler().compile(GroupedScore())

        XCTAssertEqual(compiled.tracks.count, 3)
        XCTAssertEqual(compiled.tracks.map(\.name), ["outer", "inner", "empty"])
        XCTAssertNil(compiled.tracks[0].parentID)
        XCTAssertEqual(compiled.tracks[1].parentID, compiled.tracks[0].id)
        XCTAssertNil(compiled.tracks[2].parentID)
        XCTAssertEqual(compiled.events[0].trackID, compiled.tracks[1].id)
        XCTAssertEqual(compiled.events[0].start, .half)
    }

    func testRestAffectsExtentWithoutEmittingAnEvent() throws {
        struct RestScore: Score {
            var body: some Score {
                Rest(start: .quarter, duration: .whole)
                Rest(start: .zero, duration: .zero)
                Note(pitch: try! Pitch(midiNote: 48), start: .zero, duration: .quarter)
            }
        }

        let compiled = try ScoreCompiler().compile(RestScore())

        XCTAssertEqual(compiled.events.count, 1)
        XCTAssertEqual(compiled.extent, try .quarter.adding(.whole))
    }

    func testEqualTimeOrderingFollowsDeclarationOrder() throws {
        struct OrderedScore: Score {
            var body: some Score {
                Note(pitch: try! Pitch(midiNote: 67), start: .zero, duration: .quarter)
                Note(pitch: try! Pitch(midiNote: 55), start: .zero, duration: .quarter)
            }
        }

        let compiled = try ScoreCompiler().compile(OrderedScore())

        XCTAssertEqual(compiled.events.map(\.pitch.midiNote), [67, 55])
    }

    func testTypedFailuresDoNotReturnPartialResults() throws {
        struct ZeroDurationScore: Score {
            var body: some Score {
                Note(pitch: try! Pitch(midiNote: 60), start: .zero, duration: .zero)
            }
        }

        XCTAssertThrowsError(try ScoreCompiler().compile(ZeroDurationScore())) { error in
            XCTAssertEqual(error as? ScoreCompilationError, .zeroDuration)
        }

        struct OverflowScore: Score {
            var body: some Score {
                Note(
                    pitch: try! Pitch(midiNote: 60),
                    start: try! MusicalTime(numerator: .max, denominator: 1),
                    duration: .quarter
                )
            }
        }

        XCTAssertThrowsError(try ScoreCompiler().compile(OverflowScore())) { error in
            XCTAssertEqual(error as? ScoreCompilationError, .timeOverflow)
        }

        XCTAssertThrowsError(try Pitch(midiNote: 128)) { error in
            XCTAssertEqual(error as? PitchError, .outOfRange(128))
        }
    }

    func testDepthEventAndTrackLimits() throws {
        struct NestedScore: Score {
            let remaining: Int

            var body: some Score {
                if remaining == 0 {
                    Note(pitch: try! Pitch(midiNote: 60), start: .zero, duration: .quarter)
                } else {
                    Track("nested") {
                        NestedScore(remaining: remaining - 1)
                    }
                }
            }
        }

        let depthLimited = try ScoreCompiler.Limits(
            maximumDepth: 2,
            maximumEvents: 10,
            maximumTracks: 10
        )
        XCTAssertThrowsError(
            try ScoreCompiler(limits: depthLimited).compile(NestedScore(remaining: 2))
        ) { error in
            XCTAssertEqual(
                error as? ScoreCompilationError,
                .maximumDepthExceeded(limit: 2)
            )
        }

        struct PackageNestedScore: Score {
            var body: some Score {
                Track("a") {
                    Track("b") {
                        Note(pitch: try! Pitch(midiNote: 60), start: .zero, duration: .quarter)
                    }
                }
            }
        }

        XCTAssertThrowsError(
            try ScoreCompiler(limits: depthLimited).compile(PackageNestedScore())
        ) { error in
            XCTAssertEqual(
                error as? ScoreCompilationError,
                .maximumDepthExceeded(limit: 2)
            )
        }

        struct ManyEvents: Score {
            var body: some Score {
                Note(pitch: try! Pitch(midiNote: 60), start: .zero, duration: .quarter)
                Note(pitch: try! Pitch(midiNote: 61), start: .zero, duration: .quarter)
            }
        }
        let eventLimited = try ScoreCompiler.Limits(
            maximumDepth: 10,
            maximumEvents: 1,
            maximumTracks: 10
        )
        XCTAssertThrowsError(
            try ScoreCompiler(limits: eventLimited).compile(ManyEvents())
        ) { error in
            XCTAssertEqual(
                error as? ScoreCompilationError,
                .maximumEventsExceeded(limit: 1)
            )
        }

        struct ManyTracks: Score {
            var body: some Score {
                Track("one") {}
                Track("two") {}
            }
        }
        let trackLimited = try ScoreCompiler.Limits(
            maximumDepth: 10,
            maximumEvents: 10,
            maximumTracks: 1
        )
        XCTAssertThrowsError(
            try ScoreCompiler(limits: trackLimited).compile(ManyTracks())
        ) { error in
            XCTAssertEqual(
                error as? ScoreCompilationError,
                .maximumTracksExceeded(limit: 1)
            )
        }
    }

    func testMusicalTimeIsNormalizedExactAndChecked() throws {
        XCTAssertEqual(
            try MusicalTime(numerator: 2, denominator: 4),
            try MusicalTime(numerator: 1, denominator: 2)
        )
        XCTAssertEqual(
            try MusicalTime(numerator: 1, denominator: 2).adding(
                MusicalTime(numerator: 1, denominator: 2)
            ),
            .quarter
        )
        XCTAssertEqual(
            try MusicalTime(numerator: 1, denominator: 2).adding(
                MusicalTime(numerator: 1, denominator: 3)
            ),
            try MusicalTime(numerator: 5, denominator: 6)
        )
        XCTAssertEqual(
            try MusicalTime(numerator: 2, denominator: 3).adding(
                MusicalTime(numerator: 1, denominator: 6)
            ),
            try MusicalTime(numerator: 5, denominator: 6)
        )
        XCTAssertEqual(
            try MusicalTime(numerator: 1, denominator: 6).adding(
                MusicalTime(numerator: 1, denominator: 6)
            ),
            try MusicalTime(numerator: 1, denominator: 3)
        )

        let largeLeft = try MusicalTime(numerator: .max - 1, denominator: .max)
        let largeRight = try MusicalTime(numerator: .max, denominator: .max - 1)
        XCTAssertTrue(largeLeft < largeRight)
    }

    func testTempoMapsOneCompiledScoreWithoutChangingEvents() throws {
        struct TempoScore: Score {
            var body: some Score {
                Note(pitch: try! Pitch(midiNote: 60), start: .zero, duration: .whole)
            }
        }

        let compiled = try ScoreCompiler().compile(TempoScore())
        let slow = try Tempo(beatsPerMinute: 60)
        let fast = try Tempo(beatsPerMinute: 120)

        XCTAssertEqual(try slow.seconds(for: compiled.extent), 4, accuracy: 0.000_001)
        XCTAssertEqual(try fast.seconds(for: compiled.extent), 2, accuracy: 0.000_001)
        XCTAssertEqual(compiled.events, try ScoreCompiler().compile(TempoScore()).events)
    }

    func testAvailabilityBranchesAndEmptyScoresCompile() throws {
        struct AvailabilityScore: Score {
            var body: some Score {
                if #available(macOS 14, *) {
                    Note(pitch: try! Pitch(midiNote: 72), start: .zero, duration: .quarter)
                }
            }
        }

        struct EmptyScore: Score {
            var body: some Score {}
        }

        let available = try ScoreCompiler().compile(AvailabilityScore())
        XCTAssertEqual(available.events.map(\.pitch.midiNote), [72])
        XCTAssertEqual(try ScoreCompiler().compile(EmptyScore()).extent, .zero)
    }

    func testInvalidConstructionInputsAreTyped() throws {
        XCTAssertThrowsError(try MusicalTime(numerator: 1, denominator: 0)) { error in
            XCTAssertEqual(error as? MusicalTimeError, .zeroDenominator)
        }

        XCTAssertThrowsError(try Tempo(beatsPerMinute: 0)) { error in
            XCTAssertEqual(error as? TempoError, .nonPositiveBeatsPerMinute)
        }
        XCTAssertThrowsError(try Tempo(beatsPerMinute: .nan)) { error in
            XCTAssertEqual(error as? TempoError, .nonFiniteBeatsPerMinute)
        }

        XCTAssertThrowsError(
            try ScoreCompiler.Limits(maximumDepth: 0, maximumEvents: 1, maximumTracks: 1)
        ) { error in
            XCTAssertEqual(error as? ScoreCompiler.LimitsError, .nonPositiveMaximumDepth)
        }
    }
}
