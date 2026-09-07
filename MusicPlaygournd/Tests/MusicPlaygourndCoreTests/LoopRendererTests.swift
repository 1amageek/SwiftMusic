import SwiftMusic
import XCTest
@testable import MusicPlaygourndCore

final class LoopRendererTests: XCTestCase {
    private let renderer = LoopRenderer()

    func testSynthesisProducesFinitePCMAndTrackEvents() throws {
        struct Session: Sound {
            var body: some Sound {
                Track("lead") {
                    Synthesizer(.sine).notes("C4 E4 G4")
                }
            }
        }

        let sound = try SoundCompiler().compile(Session())
        let loop = try renderer.render(sound, bpm: 120, beatsPerBar: 4)

        XCTAssertEqual(loop.sampleRate, 44_100)
        XCTAssertEqual(loop.beatCount, 4)
        XCTAssertEqual(loop.samples.count, 176_400)
        XCTAssertFalse(loop.samples.contains { !$0.isFinite })
        XCTAssertGreaterThan(loop.samples.map { abs($0) }.max() ?? 0, 0.01)
        XCTAssertEqual(loop.events.map(\.label), ["lead", "lead", "lead"])
        XCTAssertEqual(loop.events.map(\.midiNote), [60, 64, 67])
        XCTAssertEqual(loop.events.map(\.durationBeats), [4.0 / 3.0, 4.0 / 3.0, 4.0 / 3.0])
    }

    func testGainPanAndMuteChangeAudiblePCM() throws {
        let plainSound = Synthesizer(.sine).notes("C4")
        let plain = try renderer.render(
            SoundCompiler().compile(plainSound), bpm: 120, beatsPerBar: 4
        )
        let gained = try renderer.render(
            SoundCompiler().compile(plainSound.gain(0.5)), bpm: 120, beatsPerBar: 4
        )
        let panned = try renderer.render(
            SoundCompiler().compile(plainSound.pan(-1)), bpm: 120, beatsPerBar: 4
        )
        let muted = try renderer.render(
            SoundCompiler().compile(plainSound.muted()), bpm: 120, beatsPerBar: 4
        )

        let plainPeak = plain.samples.map { abs($0) }.max() ?? 0
        let gainedPeak = gained.samples.map { abs($0) }.max() ?? 0
        XCTAssertEqual(gainedPeak, plainPeak * 0.5, accuracy: 0.01)
        XCTAssertGreaterThan(panned.samples.enumerated().filter { $0.offset.isMultiple(of: 2) }.map { abs($0.element) }.max() ?? 0, 0.01)
        XCTAssertEqual(panned.samples.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map { abs($0.element) }.max() ?? 0, 0, accuracy: 0.000_001)
        XCTAssertTrue(muted.samples.allSatisfy { $0 == 0 })
    }

    func testUnsupportedSourcesEffectsAndRoutingFailExplicitly() throws {
        let delayed = try SoundCompiler().compile(
            Synthesizer(.sine).effect(.delay(time: .eighth, feedback: 0.2, wet: 0.3))
        )
        XCTAssertThrowsError(try renderer.render(delayed, bpm: 120, beatsPerBar: 4)) { error in
            guard case .unsupportedRenderNode(_, "effect") = error as? LoopRenderingError else {
                return XCTFail("Expected an explicit unsupported effect error, got \(error)")
            }
        }

        let routed = try SoundCompiler().compile(Sample("kick").output("main"))
        XCTAssertThrowsError(try renderer.render(routed, bpm: 120, beatsPerBar: 4)) { error in
            guard case .unsupportedRenderNode(_, "output") = error as? LoopRenderingError else {
                return XCTFail("Expected an explicit unsupported output error, got \(error)")
            }
        }

        let region = try SampleRegion(startFraction: 0.1, endFraction: 0.9)
        let configured = try SoundCompiler().compile(Sample("kick").sampleRegion(region))
        XCTAssertThrowsError(try renderer.render(configured, bpm: 120, beatsPerBar: 4)) { error in
            guard case .unsupportedSourceSetting(_, "sampleRegion") = error as? LoopRenderingError else {
                return XCTFail("Expected an explicit unsupported source-setting error, got \(error)")
            }
        }
    }

    func testInvalidTempoAndBoundsFailBeforeRendering() throws {
        let sound = try SoundCompiler().compile(Synthesizer(.sine))
        XCTAssertThrowsError(try renderer.render(sound, bpm: 39, beatsPerBar: 4)) { error in
            XCTAssertEqual(error as? LoopRenderingError, .invalidBPM(39))
        }
        XCTAssertThrowsError(try renderer.render(sound, bpm: 120, beatsPerBar: 1)) { error in
            XCTAssertEqual(error as? LoopRenderingError, .invalidMeter(1))
        }

        let oversized = try SoundCompiler().compile(Synthesizer(.sine).repeated(33).slow(16))
        XCTAssertThrowsError(try renderer.render(oversized, bpm: 120, beatsPerBar: 4)) { error in
            guard case .extentTooLong = error as? LoopRenderingError else {
                return XCTFail("Expected an extent bound failure, got \(error)")
            }
        }
    }

    func testGatedEventVisualDurationMatchesAudibleDuration() throws {
        let sound = try SoundCompiler().compile(Synthesizer(.sine).gate(0.5))
        let loop = try renderer.render(sound, bpm: 120, beatsPerBar: 4)
        XCTAssertEqual(loop.events.count, 1)
        XCTAssertEqual(loop.events[0].durationBeats, 0.5, accuracy: 0.000_001)
    }
}
