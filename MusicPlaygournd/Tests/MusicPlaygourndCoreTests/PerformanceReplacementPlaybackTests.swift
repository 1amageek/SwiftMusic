import AVFoundation
import Testing
@testable import MusicPlaygourndCore

struct PerformanceReplacementPlaybackTests {
    @Test(.timeLimit(.minutes(2)))
    func reservationDoesNotMutateAndRejectsASecondCandidate() throws {
        let transport = AudioTransport()
        let initial = makeLoop(scale: 0.2)
        let candidate = makeLoop(scale: 0.6, bpm: 60)
        transport.beginUpdate(revision: 1)
        try transport.submit(loop: initial, revision: 1)
        let before = transport.snapshot()

        let token = try transport.preparePerformanceReplacement(loop: candidate, revision: 1, generation: 4)
        let reservationUnchanged = transport.snapshot() == before
        #expect(reservationUnchanged)

        var rejected = false
        do {
            _ = try transport.preparePerformanceReplacement(
                loop: makeLoop(scale: 0.8), revision: 1, generation: 5
            )
        } catch {
            rejected = true
        }
        #expect(rejected)
        #expect(transport.discardPerformanceReplacement(token))
        let discardUnchanged = transport.snapshot() == before
        #expect(discardUnchanged)
    }

    @Test(.timeLimit(.minutes(2)))
    func committedReservationSurvivesSuspensionAndStop() async throws {
        let transport = AudioTransport()
        let initial = makeLoop(scale: 0.2)
        let candidate = makeLoop(scale: 0.7, bpm: 60)
        transport.beginUpdate(revision: 2)
        try transport.submit(loop: initial, revision: 2)
        try transport.startPlayback()
        _ = try render(transport, frames: 128)
        let token = try transport.preparePerformanceReplacement(loop: candidate, revision: 2, generation: 8)

        await Task.yield()
        transport.stopPlayback()
        let stoppedBeforeCommit = transport.snapshot()
        #expect(!stoppedBeforeCommit.isPlaying)
        #expect(stoppedBeforeCommit.performanceGeneration == 0)
        #expect(transport.commitPerformanceReplacement(token))
        let snapshot = transport.snapshot()
        #expect(!snapshot.isPlaying)
        #expect(snapshot.performanceGeneration == 8)
        #expect(snapshot.overrideGeneration == 0)
        #expect(snapshot.loop?.bpm == candidate.bpm)
        #expect(transport.commitPerformanceReplacement(token) == false)
        #expect(transport.discardPerformanceReplacement(token) == false)
    }

    @Test(.timeLimit(.minutes(2)))
    func invalidAndForeignTokensDoNotMutateTheTransport() throws {
        let first = AudioTransport()
        let second = AudioTransport()
        let initial = makeLoop(scale: 0.2)
        first.beginUpdate(revision: 3)
        second.beginUpdate(revision: 3)
        try first.submit(loop: initial, revision: 3)
        try second.submit(loop: initial, revision: 3)

        let before = first.snapshot()
        let firstToken = try first.preparePerformanceReplacement(
            loop: makeLoop(scale: 0.5), revision: 3, generation: 1
        )
        #expect(first.discardPerformanceReplacement(firstToken))
        let secondToken = try first.preparePerformanceReplacement(
            loop: makeLoop(scale: 0.7), revision: 3, generation: 2
        )
        let foreignToken = try second.preparePerformanceReplacement(
            loop: makeLoop(scale: 0.9), revision: 3, generation: 1
        )

        #expect(!first.commitPerformanceReplacement(firstToken))
        #expect(!first.commitPerformanceReplacement(foreignToken))
        let pendingUnchanged = first.snapshot() == before
        #expect(pendingUnchanged)
        #expect(first.discardPerformanceReplacement(secondToken))
        #expect(second.discardPerformanceReplacement(foreignToken))
        let finalUnchanged = first.snapshot() == before
        #expect(finalUnchanged)
    }

    @Test(.timeLimit(.minutes(3)))
    func changedBPMUsesSameBeatAndPublishesGenerationAfterFade() throws {
        let transport = AudioTransport()
        let initial = makeLoop(scale: 0.2, bpm: 120)
        let adopted = makeLoop(scale: 0.25, bpm: 120)
        let candidate = makeLoop(scale: 0.8, bpm: 60, beatCount: 8)
        transport.beginUpdate(revision: 4)
        try transport.submit(loop: initial, revision: 4)
        try transport.replace(loop: adopted, revision: 4, generation: 11)
        try transport.startPlayback()
        _ = try render(transport, frames: 22_000)
        let beforeBeat = transport.positionSnapshot().accumulatedBeatPosition
        let oldAtBeat = sample(loop: adopted, beat: beforeBeat)
        let token = try transport.preparePerformanceReplacement(loop: candidate, revision: 4, generation: 12)

        #expect(transport.commitPerformanceReplacement(token))
        let beforeFade = transport.snapshot()
        #expect(beforeFade.performanceGeneration == 0)
        #expect(beforeFade.overrideGeneration == 11)
        let oldLoopVisible = beforeFade.loop == adopted
        #expect(oldLoopVisible)

        let first = try render(transport, frames: 1)[0]
        #expect(abs(first - oldAtBeat) < 0.00001)
        #expect(transport.snapshot().performanceGeneration == 0)

        let remaining = try render(transport, frames: AudioTransport.crossfadeFrames - 1)
        let pcm = [first] + remaining
        let after = transport.snapshot()
        #expect(after.performanceGeneration == 12)
        #expect(after.overrideGeneration == 11)
        let candidateLoopVisible = after.loop == candidate
        #expect(candidateLoopVisible)
        let deltaBeat = candidate.bpm / 60 / candidate.sampleRate
        var maximumError: Float = 0
        for index in pcm.indices {
            let beat = beforeBeat + deltaBeat * Double(index)
            let old = sample(loop: adopted, beat: beat)
            let new = sample(loop: candidate, beat: beat)
            let mix = Float(index) / Float(AudioTransport.crossfadeFrames - 1)
            let expected = old * (1 - mix) + new * mix
            maximumError = max(maximumError, abs(pcm[index] - expected))
        }
        #expect(maximumError < 0.00001)
        let expectedBeatDelta = deltaBeat * Double(AudioTransport.crossfadeFrames)
        let actualBeatDelta = transport.positionSnapshot().accumulatedBeatPosition - beforeBeat
        #expect(abs(actualBeatDelta - expectedBeatDelta) < 0.0000000001)

        let retained = transport.drainRetiredAndRetainedIdentities()
        #expect(retained.count == 1)
    }

    @Test(.timeLimit(.minutes(3)))
    func pendingCodeAndPerformanceAdmissionPreserveOldState() throws {
        let initial = makeLoop(scale: 0.2)
        let candidate = makeLoop(scale: 0.7, bpm: 60)

        let pendingCodeTransport = AudioTransport()
        pendingCodeTransport.beginUpdate(revision: 5)
        try pendingCodeTransport.submit(loop: initial, revision: 5)
        pendingCodeTransport.beginUpdate(revision: 6)
        try pendingCodeTransport.submit(loop: makeLoop(scale: 0.4), revision: 6)
        let before = pendingCodeTransport.snapshot()
        var performanceRejected = false
        do {
            _ = try pendingCodeTransport.preparePerformanceReplacement(
                loop: candidate, revision: 5, generation: 3
            )
        } catch {
            performanceRejected = true
        }
        #expect(performanceRejected)
        let pendingCodeUnchanged = pendingCodeTransport.snapshot() == before
        #expect(pendingCodeUnchanged)

        let pendingPerformanceTransport = AudioTransport()
        pendingPerformanceTransport.beginUpdate(revision: 5)
        try pendingPerformanceTransport.submit(loop: initial, revision: 5)
        try pendingPerformanceTransport.startPlayback()
        let token = try pendingPerformanceTransport.preparePerformanceReplacement(
            loop: candidate, revision: 5, generation: 3
        )
        pendingPerformanceTransport.beginUpdate(revision: 6)
        var codeRejected = false
        do {
            try pendingPerformanceTransport.submit(loop: makeLoop(scale: 0.4), revision: 6)
        } catch {
            codeRejected = true
        }
        #expect(codeRejected)
        #expect(pendingPerformanceTransport.commitPerformanceReplacement(token))
        _ = try render(pendingPerformanceTransport, frames: AudioTransport.crossfadeFrames)
        #expect(pendingPerformanceTransport.snapshot().revision == 5)
        #expect(pendingPerformanceTransport.snapshot().performanceGeneration == 3)
        let retained = pendingPerformanceTransport.drainRetiredAndRetainedIdentities()
        #expect(retained.count == 1)
    }

    @Test(.timeLimit(.minutes(2)))
    func invalidCandidateFailsBeforeReservationMutation() throws {
        let transport = AudioTransport()
        let initial = makeLoop(scale: 0.2)
        transport.beginUpdate(revision: 7)
        try transport.submit(loop: initial, revision: 7)
        let before = transport.snapshot()
        let invalid = PreparedLoop(
            sampleRate: 48_000,
            bpm: 120,
            beatsPerBar: 4,
            beatCount: 4,
            samples: initial.samples,
            events: []
        )

        var rejected = false
        do {
            _ = try transport.preparePerformanceReplacement(loop: invalid, revision: 7, generation: 1)
        } catch {
            rejected = true
        }
        #expect(rejected)
        let invalidUnchanged = transport.snapshot() == before
        #expect(invalidUnchanged)
    }

    private func makeLoop(scale: Float, bpm: Double = 120, beatCount: Double = 4) -> PreparedLoop {
        let frameCount = Int((beatCount * 60 / bpm * PreparedLoop.requiredSampleRate).rounded(.up))
        var samples = [Float](repeating: 0, count: frameCount * 2)
        let denominator = Float(max(1, frameCount - 1))
        for frame in 0..<frameCount {
            let value = scale * (0.2 + 0.8 * Float(frame) / denominator)
            samples[frame * 2] = value
            samples[frame * 2 + 1] = -value
        }
        return PreparedLoop(
            sampleRate: PreparedLoop.requiredSampleRate,
            bpm: bpm,
            beatsPerBar: 4,
            beatCount: beatCount,
            samples: samples,
            events: []
        )
    }

    private func sample(loop: PreparedLoop, beat: Double) -> Float {
        let frameCount = max(1, loop.samples.count / 2)
        let localBeat = beat.truncatingRemainder(dividingBy: loop.beatCount)
        let position = max(0, localBeat / loop.beatCount * Double(frameCount))
        let lower = Int(position.rounded(.down)) % frameCount
        let upper = (lower + 1) % frameCount
        let fraction = Float(position - floor(position))
        let a = loop.samples[lower * 2]
        let b = loop.samples[upper * 2]
        return a + (b - a) * fraction
    }

    private func render(_ transport: AudioTransport, frames: Int) throws -> [Float] {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: PreparedLoop.requiredSampleRate,
            channels: 2
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_048))
        var result: [Float] = []
        result.reserveCapacity(frames)
        while result.count < frames {
            let count = min(2_048, frames - result.count)
            buffer.frameLength = AVAudioFrameCount(count)
            #expect(transport.render(
                frameCount: count,
                audioBufferList: buffer.mutableAudioBufferList
            ) == noErr)
            let channels = try #require(buffer.floatChannelData)
            for frame in 0..<count {
                result.append(channels[0][frame])
            }
        }
        return result
    }
}
