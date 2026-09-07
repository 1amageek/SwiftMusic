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
}
