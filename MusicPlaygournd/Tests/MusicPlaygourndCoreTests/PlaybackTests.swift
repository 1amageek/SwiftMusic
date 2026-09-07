import AVFoundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct PlaybackTests {
    @Test(.timeLimit(.minutes(3)))
    func testSampleCallbackKeepsPlayingThroughInvalidatedAndStaleUpdates() throws {
        let plan = try SoundCompiler().compile(Synthesizer(.sine).notes("C3 C3 C3 C3"))
        let first = try LoopRenderer().render(plan, bpm: 120, beatsPerBar: 4)
        let next = try LoopRenderer().render(plan, bpm: 60, beatsPerBar: 4)
        let transport = AudioTransport()
        transport.beginUpdate(revision: 1)
        try transport.submit(loop: first, revision: 1)
        try transport.startPlayback()
        let audio = try advance(transport, frames: 512)
        #expect(audio > 0.01)
        let position = transport.snapshot().beatPosition
        transport.beginUpdate(revision: 2)
        try transport.submit(loop: next, revision: 2)
        transport.beginUpdate(revision: 3)
        #expect(throws: (any Error).self) { try transport.submit(loop: next, revision: 2) }
        #expect(try advance(transport, frames: 512) > 0.01)
        #expect(transport.snapshot().revision == 1)
        #expect(transport.snapshot().beatPosition > position)
        try transport.submit(loop: next, revision: 3)
        #expect(throws: (any Error).self) { try transport.submit(loop: next, revision: 3) }
        _ = try advance(transport, frames: 88_200 - 1_024)
        #expect(transport.snapshot().revision == 1)
        _ = try advance(transport, frames: 2)
        #expect(transport.snapshot().revision == 3)
        #expect(transport.snapshot().loop?.bpm == 60)
        #expect(transport.snapshot().beatPosition < 0.001)
        transport.stopPlayback()
        let paused = transport.snapshot().beatPosition
        #expect(try advance(transport, frames: 512) == 0)
        #expect(transport.snapshot().beatPosition == paused)
        try transport.startPlayback()
        _ = try advance(transport, frames: 512)
        #expect(transport.snapshot().beatPosition > paused)
    }

    private func advance(_ transport: AudioTransport, frames: Int) throws -> Float {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        var remaining = frames
        var peak: Float = 0
        while remaining > 0 {
            let count = min(remaining, 1_024)
            buffer.frameLength = AVAudioFrameCount(count)
            #expect(transport.render(frameCount: count, audioBufferList: buffer.mutableAudioBufferList) == noErr)
            let channels = try #require(buffer.floatChannelData)
            for index in 0..<count { peak = max(peak, abs(channels[0][index]), abs(channels[1][index])) }
            remaining -= count
        }
        return peak
    }
}
