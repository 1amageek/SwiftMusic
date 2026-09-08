import AVFoundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct PlaybackClockAnchorTests {
    @Test func mappingRejectsStaleOverflowAndStoppedScheduling() throws {
        let time = AVAudioTime.hostTime(forSeconds: 100)
        let anchor = try PlaybackClockAnchor(presentationHostTime: time, accumulatedBeatPosition: 8,
            beatsPerMinute: 120, loopBeatCount: 4, revision: 7, overrideGeneration: 2, isPlaying: true)
        let next = try anchor.hostTime(atBeat: 9)
        #expect(abs(try anchor.beat(atHostTime: next) - 9) < 0.000001)
        #expect(abs(try anchor.beat(atHostTime: time - AVAudioTime.hostTime(forSeconds: 0.5)) - 7) < 0.000001)
        #expect(try anchor.hostTime(atBeat: 7) == time - AVAudioTime.hostTime(forSeconds: 0.5))
        #expect(throws: PlaybackClockError.outOfRange) { try anchor.hostTime(atBeat: -1) }
        #expect(throws: PlaybackClockError.discontinuous) {
            try anchor.beat(atHostTime: time + AVAudioTime.hostTime(forSeconds: 2))
        }
        let stopped = try PlaybackClockAnchor(presentationHostTime: time, accumulatedBeatPosition: 8,
            beatsPerMinute: 120, loopBeatCount: 4, revision: 7, overrideGeneration: 2, isPlaying: false)
        #expect(try stopped.beat(atHostTime: UInt64.max) == 8)
        #expect(throws: PlaybackClockError.unavailable) { try stopped.hostTime(atBeat: 8) }
        let overflow = try PlaybackClockAnchor(presentationHostTime: UInt64.max, accumulatedBeatPosition: 0,
            beatsPerMinute: 120, loopBeatCount: 4, revision: 0, overrideGeneration: 0, isPlaying: true)
        #expect(throws: PlaybackClockError.outOfRange) { try overflow.hostTime(atBeat: 1) }
        #expect(throws: PlaybackClockError.outOfRange) {
            try PlaybackClockAnchor(presentationHostTime: 0, accumulatedBeatPosition: 0,
                beatsPerMinute: 120, loopBeatCount: 4, revision: 0, overrideGeneration: 0, isPlaying: true)
        }
    }

    @Test(.timeLimit(.minutes(1))) func transportMaintainsUnwrappedClockAcrossLifecycle() throws {
        let plan = try SoundCompiler().compile(Synthesizer(.sine).notes("C4"))
        let loop = try LoopRenderer().render(plan, bpm: 120, beatsPerBar: 4)
        let transport = AudioTransport()
        transport.beginUpdate(revision: 1)
        try transport.submit(loop: loop, revision: 1)
        try transport.startPlayback()
        #expect(throws: PlaybackClockError.unavailable) { try transport.clockAnchor(presentationLatency: 0) }
        let time = AVAudioTime.hostTime(forSeconds: 100)
        try advance(transport, frames: 88_200, hostTime: time)
        let first = try transport.clockAnchor(presentationLatency: 0.1)
        #expect(first.accumulatedBeatPosition == 0)
        #expect(first.presentationHostTime == time + AVAudioTime.hostTime(forSeconds: 0.1))
        let next = time + AVAudioTime.hostTime(forSeconds: 2)
        try advance(transport, frames: 512, hostTime: next)
        let wrapped = try transport.clockAnchor(presentationLatency: 0)
        #expect(abs(wrapped.accumulatedBeatPosition - 4) < 0.000001)
        transport.setClockRate(2)
        #expect(throws: PlaybackClockError.unavailable) { try transport.clockAnchor(presentationLatency: 0) }
        try advance(transport, frames: 512, hostTime: next + 1)
        let faster = try transport.clockAnchor(presentationLatency: 0.1)
        #expect(faster.beatsPerMinute == 240)
        #expect(abs(try faster.beat(atHostTime: faster.presentationHostTime + AVAudioTime.hostTime(forSeconds: 0.5))
            - faster.accumulatedBeatPosition - 2) < 0.000001)
        try transport.replace(loop: loop, revision: 1, generation: 1)
        #expect(throws: PlaybackClockError.unavailable) { try transport.clockAnchor(presentationLatency: 0) }
        try advance(transport, frames: 512, hostTime: next + 2)
        #expect(try transport.clockAnchor(presentationLatency: 0).overrideGeneration == 1)
        try advance(transport, frames: 512, hostTime: next + 2)
        #expect(throws: PlaybackClockError.discontinuous) { try transport.clockAnchor(presentationLatency: 0) }
        transport.stopPlayback()
        let stopped = try transport.clockAnchor(presentationLatency: 0, now: next + 3)
        #expect(!stopped.isPlaying)
        #expect(stopped.accumulatedBeatPosition > 4)
        transport.beginUpdate(revision: 2)
        try transport.submit(loop: loop, revision: 2)
        try transport.startPlayback()
        #expect(throws: PlaybackClockError.unavailable) { try transport.clockAnchor(presentationLatency: 0) }
        try advance(transport, frames: 512, hostTime: next + 4)
        let adopted = try transport.clockAnchor(presentationLatency: 0)
        #expect(adopted.revision == 2)
        #expect(adopted.accumulatedBeatPosition == stopped.accumulatedBeatPosition)
        #expect(adopted.overrideGeneration == 0)
        try advance(transport, frames: 512, hostTime: nil)
        #expect(throws: PlaybackClockError.unavailable) { try transport.clockAnchor(presentationLatency: 0) }
    }

    @Test(.timeLimit(.minutes(1))) func restartPreservesCurrentAndPendingRevision() throws {
        let loop = try LoopRenderer().render(SoundCompiler().compile(Synthesizer(.sine).notes("C4")),
            bpm: 120, beatsPerBar: 4)
        let transport = AudioTransport()
        transport.beginUpdate(revision: 1)
        try transport.submit(loop: loop, revision: 1)
        try transport.startPlayback()
        try advance(transport, frames: 1_024, hostTime: 100)
        transport.beginUpdate(revision: 2)
        try transport.submit(loop: loop, revision: 2)
        try transport.restartFromBeginning()
        #expect(transport.snapshot().revision == 1)
        #expect(transport.snapshot().beatPosition == 0)
        #expect(transport.positionSnapshot().accumulatedBeatPosition == 0)
        try advance(transport, frames: 88_202, hostTime: 101)
        #expect(transport.snapshot().revision == 2)
    }

    private func advance(_ transport: AudioTransport, frames: Int, hostTime: UInt64?) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        #expect(transport.render(frameCount: frames, audioBufferList: buffer.mutableAudioBufferList,
            hostTime: hostTime) == noErr)
    }
}

extension NativeHostTests {
    @MainActor struct NativePlaybackClockTests {
        @Test(.timeLimit(.minutes(1))) func actualSourceCallbackSuppliesPresentationClock() async throws {
            let engine = try AudioLoopEngine()
            let plan = try SoundCompiler().compile(Synthesizer(.sine).notes("C4").gain(0.001))
            let loop = try LoopRenderer().render(plan, bpm: 120, beatsPerBar: 4)
            engine.beginUpdate(revision: 51)
            try engine.submit(loop: loop, revision: 51)
            try engine.play()
            defer { engine.stop() }
            try await Task.sleep(for: .milliseconds(350))
            let first = try engine.playbackClockAnchor()
            #expect(first.isPlaying)
            #expect(first.revision == 51)
            #expect(first.presentationHostTime > 0)
            try engine.setPlaybackRate(2)
            try await Task.sleep(for: .milliseconds(350))
            let faster = try engine.playbackClockAnchor()
            #expect(faster.beatsPerMinute == 240)
            #expect(faster.accumulatedBeatPosition > first.accumulatedBeatPosition)
            #expect(faster.presentationHostTime > first.presentationHostTime)
            engine.stop()
            let stopped = try engine.playbackClockAnchor()
            #expect(!stopped.isPlaying)
            #expect(try stopped.beat(atHostTime: UInt64.max) == stopped.accumulatedBeatPosition)
        }
    }
}
