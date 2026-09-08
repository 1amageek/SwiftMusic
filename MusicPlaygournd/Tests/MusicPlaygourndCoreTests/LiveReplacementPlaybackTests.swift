import AVFoundation
import Testing
@testable import MusicPlaygourndCore

struct LiveReplacementPlaybackTests {
    @Test(.timeLimit(.minutes(3)))
    func replacementCrossfadesAtCurrentPhaseAndKeepsOnlyLatestPending() throws {
        let transport = AudioTransport()
        let first = loop(scale: 0.2), second = loop(scale: 0.6)
        transport.beginUpdate(revision: 1)
        try transport.submit(loop: first, revision: 1)
        try transport.startPlayback()
        _ = try render(transport, frames: 87_700)
        let beat = transport.positionSnapshot().accumulatedBeatPosition
        try transport.replace(loop: second, revision: 1, generation: 1)
        try transport.replace(loop: loop(scale: 0.7), revision: 1, generation: 2)
        try transport.replace(loop: loop(scale: 0.8), revision: 1, generation: 3)
        #expect(transport.snapshot().overrideGeneration == 1)
        let pcm = try render(transport, frames: AudioTransport.crossfadeFrames)
        var maximumError: Float = 0
        for index in pcm.indices {
            let frame = (87_700 + index) % 88_200
            let weight = Float(index) / Float(AudioTransport.crossfadeFrames - 1)
            let expected = first.samples[frame * 2] * (1 - weight) + second.samples[frame * 2] * weight
            maximumError = max(maximumError, abs(pcm[index] - expected))
        }
        #expect(maximumError < 0.000001)
        #expect(abs(transport.positionSnapshot().accumulatedBeatPosition - beat - 0.06) < 0.000001)
        // A retired slot prevents starting another fade before the host drains ownership.
        _ = try render(transport, frames: 1)
        #expect(transport.snapshot().overrideGeneration == 1)
        let retained = transport.drainRetiredAndRetainedIdentities()
        #expect(retained.count == 2)
        #expect(!retained.contains(.init(revision: 1, generation: 2)))
        _ = try render(transport, frames: AudioTransport.crossfadeFrames)
        #expect(transport.snapshot().overrideGeneration == 3)
        #expect(transport.snapshot().revision == 1)
    }

    @Test(.timeLimit(.minutes(3)))
    func invalidReplacementPreservesStateAndCodeAdoptionInvalidatesGeneration() throws {
        let transport = AudioTransport()
        transport.beginUpdate(revision: 4)
        try transport.submit(loop: loop(scale: 0.2), revision: 4)
        try transport.startPlayback()
        _ = try render(transport, frames: 88_190)
        try transport.replace(loop: loop(scale: 0.5), revision: 4, generation: 7)
        let before = transport.snapshot()
        #expect(throws: PlaybackError.staleOverrideGeneration(7)) {
            try transport.replace(loop: loop(scale: 0.8), revision: 4, generation: 7)
        }
        #expect(throws: PlaybackError.incompatibleReplacement) {
            try transport.replace(loop: loop(scale: 0.8, bpm: 60), revision: 4, generation: 8)
        }
        #expect(transport.snapshot() == before)
        transport.beginUpdate(revision: 5)
        try transport.submit(loop: loop(scale: 0.3), revision: 5)
        _ = try render(transport, frames: 12)
        #expect(transport.snapshot().revision == 5)
        #expect(transport.snapshot().overrideGeneration == 0)
        #expect(throws: PlaybackError.staleRevision(4)) {
            try transport.replace(loop: loop(scale: 0.8), revision: 4, generation: 9)
        }
        try transport.replace(loop: loop(scale: 0.8), revision: 5, generation: 1)
        transport.stopPlayback()
        #expect(transport.snapshot().overrideGeneration == 1)
        #expect(transport.drainRetiredAndRetainedIdentities().count == 1)
        #expect(try render(transport, frames: 8).allSatisfy { $0 == 0 })
    }

    @Test(.timeLimit(.minutes(3)))
    func replacementAllowsAudibleMetadataButRejectsChangedEventIdentity() throws {
        let transport = AudioTransport()
        let base = loop(scale: 0.2)
        func value(start: Double, gain: Double, peak: Float) -> PreparedLoop {
            PreparedLoop(sampleRate: base.sampleRate, bpm: base.bpm,
                beatsPerBar: base.beatsPerBar, beatCount: base.beatCount, samples: base.samples,
                events: [LoopEvent(sourceID: 0, label: "Voice", startBeat: start,
                    durationBeats: gain, midiNote: 60, velocity: 100, patternStepIndex: 0, gain: gain)],
                rows: [LoopRow(sourceID: 0, label: "Voice", anchor: nil, peaks: [peak])])
        }
        transport.beginUpdate(revision: 1)
        try transport.submit(loop: value(start: 0, gain: 1, peak: 0.2), revision: 1)
        try transport.replace(loop: value(start: 0, gain: 0.5, peak: 0.1), revision: 1, generation: 1)
        #expect(transport.snapshot().loop?.events.first?.gain == 0.5)
        #expect(transport.snapshot().loop?.rows.first?.peaks.first == 0.1)
        #expect(throws: PlaybackError.incompatibleReplacement) {
            try transport.replace(loop: value(start: 1, gain: 0.5, peak: 0.1), revision: 1, generation: 2)
        }
        #expect(transport.snapshot().overrideGeneration == 1)
    }

    private func loop(scale: Float, bpm: Double = 120) -> PreparedLoop {
        var samples = [Float](repeating: 0, count: 88_200 * 2)
        for frame in 0..<88_200 {
            let value = scale * Float(frame % 100) / 100
            samples[frame * 2] = value
            samples[frame * 2 + 1] = -value
        }
        return PreparedLoop(sampleRate: 44_100, bpm: bpm, beatsPerBar: 4,
                            beatCount: 4, samples: samples, events: [])
    }

    private func render(_ transport: AudioTransport, frames: Int) throws -> [Float] {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        var result: [Float] = []
        result.reserveCapacity(frames)
        while result.count < frames {
            let count = min(1_024, frames - result.count)
            buffer.frameLength = AVAudioFrameCount(count)
            #expect(transport.render(frameCount: count, audioBufferList: buffer.mutableAudioBufferList) == noErr)
            let data = try #require(buffer.floatChannelData)
            for index in 0..<count { result.append(data[0][index]) }
        }
        return result
    }
}
