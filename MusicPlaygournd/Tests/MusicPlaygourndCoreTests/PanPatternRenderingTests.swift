import Foundation
import SwiftMusic
import XCTest
@testable import MusicPlaygourndCore

final class PanPatternRenderingTests: XCTestCase {
    func testPatternedPanAndGainReachStereoPCM() throws {
        let sound = Synthesizer(.sine).notes("C4 C4 C4 C4")
        let renderer = LoopRenderer()
        let plain = try renderer.render(SoundCompiler().compile(sound), bpm: 120, beatsPerBar: 4)
        let loop = try renderer.render(SoundCompiler().compile(
            sound.pan("-1 1 0 -1").gain("1 0.5 1 0")
        ), bpm: 120, beatsPerBar: 4)
        XCTAssertEqual(loop.events.map(\.pan), [-1, 1, 0, -1])
        XCTAssertEqual(loop.events.map(\.gain), [1, 0.5, 1, 0])
        XCTAssertTrue(plain.events.allSatisfy { $0.pan == nil })
        let leftGains: [Float] = [1, 0, sqrt(0.5), 0]
        let rightGains: [Float] = [0, 0.5, sqrt(0.5), 0]
        var maximumError: Float = 0
        for frame in 0..<(plain.samples.count / 2) {
            let beat = frame / 22_050
            maximumError = max(maximumError, abs(loop.samples[frame * 2] - plain.samples[frame * 2] * leftGains[beat]),
                abs(loop.samples[frame * 2 + 1] - plain.samples[frame * 2 + 1] * rightGains[beat]))
        }
        XCTAssertLessThan(maximumError, 0.000_001)
        let centered = try renderer.render(SoundCompiler().compile(sound.pan("0")), bpm: 120, beatsPerBar: 4)
        let scalar = try renderer.render(SoundCompiler().compile(sound.pan(0)), bpm: 120, beatsPerBar: 4)
        XCTAssertEqual(centered.samples, scalar.samples)
    }

    func testPanMetadataDecodesLegacyAndRejectsInvalidValues() throws {
        let legacy = Data(#"{"sourceID":0,"label":"test","startBeat":0,"durationBeats":1,"gain":1,"velocity":80}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(LoopEvent.self, from: legacy).pan)
        let valid = try LoopRenderer().render(SoundCompiler().compile(Sample("kick")), bpm: 120, beatsPerBar: 4)
        for pan in [2.0, Double.nan, Double.infinity] {
            let invalid = PreparedLoop(sampleRate: valid.sampleRate, bpm: valid.bpm,
                beatsPerBar: valid.beatsPerBar, beatCount: valid.beatCount, samples: valid.samples,
                events: [LoopEvent(sourceID: 0, label: "test", startBeat: 0, durationBeats: 1,
                    midiNote: nil, velocity: 80, pan: pan)], rows: valid.rows)
            XCTAssertThrowsError(try invalid.validate())
        }
    }
}
