import XCTest
@testable import MusicPlaygourndCore

final class PreparedLoopTests: XCTestCase {
    func testDecodedLoopValidationRejectsNonFiniteAndMismatchedSamples() throws {
        let invalidSamples = PreparedLoop(
            sampleRate: 44_100,
            bpm: 120,
            beatsPerBar: 4,
            beatCount: 4,
            samples: [Float.nan, 0],
            events: []
        )
        XCTAssertThrowsError(try invalidSamples.validate()) { error in
            XCTAssertEqual(error as? PreparedLoopValidationError, .invalidSampleCount(2))
        }

        let invalidEvent = PreparedLoop(
            sampleRate: 44_100,
            bpm: 120,
            beatsPerBar: 4,
            beatCount: 4,
            samples: Array(repeating: 0, count: 176_400),
            events: [LoopEvent(
                sourceID: 0,
                label: "lead",
                startBeat: 0,
                durationBeats: 1,
                midiNote: 128,
                velocity: 80
            )]
        )
        XCTAssertThrowsError(try invalidEvent.validate()) { error in
            guard case .invalidEvent(index: 0, reason: "MIDI note is out of range") = error as? PreparedLoopValidationError else {
                return XCTFail("Expected an event validation error, got \(error)")
            }
        }
    }

    func testDecodedLoopValidationRejectsDuplicateRowsAndInvalidPeaks() throws {
        let duplicateRows = PreparedLoop(
            sampleRate: 44_100,
            bpm: 120,
            beatsPerBar: 4,
            beatCount: 4,
            samples: Array(repeating: 0, count: 176_400),
            events: [],
            rows: [
                LoopRow(sourceID: 0, label: "first", anchor: nil, peaks: [0]),
                LoopRow(sourceID: 0, label: "second", anchor: nil, peaks: [0])
            ]
        )
        XCTAssertThrowsError(try duplicateRows.validate()) { error in
            guard case .invalidRow(index: 1, reason: "duplicate source ID") = error as? PreparedLoopValidationError else {
                return XCTFail("Expected duplicate row validation error, got \(error)")
            }
        }

        let invalidPeaks = PreparedLoop(
            sampleRate: 44_100,
            bpm: 120,
            beatsPerBar: 4,
            beatCount: 4,
            samples: Array(repeating: 0, count: 176_400),
            events: [],
            rows: [
                LoopRow(sourceID: 0, label: "lead", anchor: nil, peaks: [Float.nan])
            ]
        )
        XCTAssertThrowsError(try invalidPeaks.validate()) { error in
            guard case .invalidRow(index: 0, reason: "peak envelope contains an invalid value") = error as? PreparedLoopValidationError else {
                return XCTFail("Expected invalid peak validation error, got \(error)")
            }
        }

        let negativePatternIndex = PreparedLoop(
            sampleRate: 44_100,
            bpm: 120,
            beatsPerBar: 4,
            beatCount: 4,
            samples: Array(repeating: 0, count: 176_400),
            events: [LoopEvent(
                sourceID: 0,
                label: "lead",
                startBeat: 0,
                durationBeats: 1,
                midiNote: 60,
                velocity: 80,
                patternStepIndex: -1
            )],
            rows: [LoopRow(sourceID: 0, label: "lead", anchor: nil, peaks: [0], patternText: "x ~")]
        )
        XCTAssertThrowsError(try negativePatternIndex.validate()) { error in
            guard case .invalidEvent(index: 0, reason: "negative pattern step index") = error as? PreparedLoopValidationError else {
                return XCTFail("Expected negative pattern index validation error, got \(error)")
            }
        }

        let outOfRangePatternIndex = PreparedLoop(
            sampleRate: 44_100,
            bpm: 120,
            beatsPerBar: 4,
            beatCount: 4,
            samples: Array(repeating: 0, count: 176_400),
            events: [LoopEvent(
                sourceID: 0,
                label: "lead",
                startBeat: 0,
                durationBeats: 1,
                midiNote: 60,
                velocity: 80,
                patternStepIndex: 2
            )],
            rows: [LoopRow(sourceID: 0, label: "lead", anchor: nil, peaks: [0], patternText: "x ~")]
        )
        XCTAssertThrowsError(try outOfRangePatternIndex.validate()) { error in
            guard case .invalidEvent(index: 0, reason: "pattern step index is outside pattern text") = error as? PreparedLoopValidationError else {
                return XCTFail("Expected pattern text bound validation error, got \(error)")
            }
        }
    }
}
