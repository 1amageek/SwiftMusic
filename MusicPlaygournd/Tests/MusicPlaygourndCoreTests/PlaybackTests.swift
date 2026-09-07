import AVFoundation
import SwiftMusic
import XCTest
@testable import MusicPlaygourndCore

final class PlaybackTests: XCTestCase {
    func testSampleCallbackKeepsPlayingThroughInvalidatedAndStaleUpdates() throws {
        let plan = try SoundCompiler().compile(Synthesizer(.sine).notes("C3 C3 C3 C3"))
        let first = try LoopRenderer().render(plan, bpm: 120, beatsPerBar: 4)
        let next = try LoopRenderer().render(plan, bpm: 60, beatsPerBar: 4)
        let transport = AudioTransport()
        transport.beginUpdate(revision: 1)
        try transport.submit(loop: first, revision: 1)
        try transport.startPlayback()
        let audio = try advance(transport, frames: 512)
        XCTAssertGreaterThan(audio, 0.01)
        let position = transport.snapshot().beatPosition
        transport.beginUpdate(revision: 2)
        try transport.submit(loop: next, revision: 2)
        transport.beginUpdate(revision: 3)
        XCTAssertThrowsError(try transport.submit(loop: next, revision: 2))
        XCTAssertGreaterThan(try advance(transport, frames: 512), 0.01)
        XCTAssertEqual(transport.snapshot().revision, 1)
        XCTAssertGreaterThan(transport.snapshot().beatPosition, position)
        try transport.submit(loop: next, revision: 3)
        XCTAssertThrowsError(try transport.submit(loop: next, revision: 3))
        _ = try advance(transport, frames: 88_200 - 1_024)
        XCTAssertEqual(transport.snapshot().revision, 1)
        _ = try advance(transport, frames: 2)
        XCTAssertEqual(transport.snapshot().revision, 3)
        XCTAssertEqual(transport.snapshot().loop?.bpm, 60)
        XCTAssertLessThan(transport.snapshot().beatPosition, 0.001)
        transport.stopPlayback()
        let paused = transport.snapshot().beatPosition
        XCTAssertEqual(try advance(transport, frames: 512), 0)
        XCTAssertEqual(transport.snapshot().beatPosition, paused)
        try transport.startPlayback()
        _ = try advance(transport, frames: 512)
        XCTAssertGreaterThan(transport.snapshot().beatPosition, paused)
    }

    private func advance(_ transport: AudioTransport, frames: Int) throws -> Float {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        var remaining = frames
        var peak: Float = 0
        while remaining > 0 {
            let count = min(remaining, 1_024)
            buffer.frameLength = AVAudioFrameCount(count)
            XCTAssertEqual(transport.render(frameCount: count, audioBufferList: buffer.mutableAudioBufferList), noErr)
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for index in 0..<count { peak = max(peak, abs(channels[0][index]), abs(channels[1][index])) }
            remaining -= count
        }
        return peak
    }
}
