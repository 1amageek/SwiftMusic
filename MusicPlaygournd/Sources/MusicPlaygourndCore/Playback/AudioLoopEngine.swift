import AVFoundation
import Foundation
import Synchronization

@MainActor
public final class AudioLoopEngine {
    private let audioEngine: AVAudioEngine
    private let sourceNode: AVAudioSourceNode
    private let transport: AudioTransport
    private var retainedLoops: [UInt64: PreparedLoop] = [:]
    private var latestRequestedRevision: UInt64?

    public init() throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: PreparedLoop.requiredSampleRate,
            channels: 2
        ) else {
            throw PlaybackError.audioSetupFailed("Unable to create a 44.1 kHz stereo format.")
        }

        let transport = AudioTransport()
        let sourceNode = AVAudioSourceNode(format: format) { @Sendable [transport] isSilence, _, frameCount, audioBufferList in
            let status = transport.render(frameCount: Int(frameCount), audioBufferList: audioBufferList)
            isSilence.pointee = ObjCBool(status != noErr)
            return status
        }
        let audioEngine = AVAudioEngine()
        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: format)
        audioEngine.mainMixerNode.outputVolume = 1
        audioEngine.prepare()

        self.transport = transport
        self.sourceNode = sourceNode
        self.audioEngine = audioEngine
    }

    public func beginUpdate(revision: UInt64) {
        guard latestRequestedRevision.map({ revision > $0 }) ?? true else { return }
        latestRequestedRevision = revision
        transport.beginUpdate(revision: revision)
        pruneRetainedLoops()
    }

    public func submit(loop: PreparedLoop, revision: UInt64) throws {
        do {
            try loop.validate()
        } catch let error as PreparedLoopValidationError {
            throw PlaybackError.invalidLoop(error)
        }
        try transport.submit(loop: loop, revision: revision)
        retainedLoops[revision] = loop
        pruneRetainedLoops()
    }

    public func play() throws {
        try transport.startPlayback()
        do {
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
        } catch {
            transport.stopPlayback()
            audioEngine.stop()
            throw PlaybackError.audioStartFailed(String(describing: error))
        }
    }

    public func stop() {
        transport.stopPlayback()
        audioEngine.stop()
        pruneRetainedLoops()
    }

    public func snapshot() -> PlaybackSnapshot {
        let snapshot = transport.snapshot()
        pruneRetainedLoops(currentRevision: snapshot.revision)
        return snapshot
    }

    private func pruneRetainedLoops(currentRevision: UInt64? = nil) {
        let activeRevision = currentRevision ?? transport.snapshot().revision
        let retained = Set([activeRevision, latestRequestedRevision].compactMap { $0 })
        retainedLoops = retainedLoops.filter { retained.contains($0.key) }
    }
}

// The callback crosses AVFAudio's render thread. Its only mutable field is Mutex-protected,
// and callback-local buffer borrows never escape this method.
final class AudioTransport: Sendable {
    private struct Candidate: Sendable {
        let loop: PreparedLoop
        let revision: UInt64
    }

    private struct State: Sendable {
        var current: PreparedLoop?
        var currentRevision: UInt64?
        var pending: Candidate?
        var latestRevision: UInt64?
        var submittedRevision: UInt64?
        var beatPosition = 0.0
        var framePosition = 0
        var pendingBoundary: Double?
        var isPlaying = false
    }

    private let state = Mutex(State())

    func beginUpdate(revision: UInt64) {
        state.withLock { state in
            guard state.latestRevision.map({ revision > $0 }) ?? true else { return }
            state.latestRevision = revision
            state.submittedRevision = nil
            state.pending = nil
            state.pendingBoundary = nil
        }
    }

    func submit(loop: PreparedLoop, revision: UInt64) throws {
        try state.withLock { state in
            guard state.latestRevision == revision else {
                throw state.latestRevision.map { _ in PlaybackError.staleRevision(revision) }
                    ?? PlaybackError.updateNotStarted(revision)
            }
            guard state.submittedRevision != revision else {
                throw PlaybackError.duplicateRevision(revision)
            }

            state.submittedRevision = revision
            let candidate = Candidate(loop: loop, revision: revision)
            if state.current == nil {
                state.current = loop
                state.currentRevision = revision
                state.pending = nil
                state.framePosition = 0
            } else {
                state.pending = candidate
                if state.isPlaying, let current = state.current {
                    let meter = Double(current.beatsPerBar)
                    state.pendingBoundary = (floor(state.beatPosition / meter) + 1) * meter
                }
            }
        }
    }

    func startPlayback() throws {
        try state.withLock { state in
            guard state.current != nil || state.pending != nil else {
                throw PlaybackError.noCurrentLoop
            }
            if let pending = state.pending, !state.isPlaying {
                adopt(pending, into: &state)
            }
            state.isPlaying = true
        }
    }

    func stopPlayback() {
        state.withLock { $0.isPlaying = false }
    }

    func snapshot() -> PlaybackSnapshot {
        state.withLock { state in
            let beatPosition: Double
            if let current = state.current {
                let frames = max(1, current.samples.count / 2)
                beatPosition = Double(state.framePosition) / Double(frames) * current.beatCount
            } else {
                beatPosition = 0
            }
            return PlaybackSnapshot(
                loop: state.current,
                revision: state.currentRevision,
                beatPosition: beatPosition,
                isPlaying: state.isPlaying
            )
        }
    }

    func render(frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard frameCount > 0 else { return noErr }
        return state.withLock { state in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            // AVFAudio owns aligned non-interleaved Float32 stereo storage. Capacity is checked
            // before binding; pointers and offsets stay within this callback and never escape.
            guard buffers.count == 2, buffers.allSatisfy({
                $0.mNumberChannels == 1 && $0.mData != nil &&
                Int($0.mDataByteSize) / MemoryLayout<Float>.stride >= frameCount
            }) else { return kAudio_ParamError }
            guard state.isPlaying, state.current != nil else {
                for buffer in buffers {
                    if let data = buffer.mData { memset(data, 0, frameCount * MemoryLayout<Float>.stride) }
                }
                return noErr
            }

            for offset in 0..<frameCount {
                if let pending = state.pending,
                   let boundary = state.pendingBoundary,
                   state.beatPosition >= boundary {
                    adopt(pending, into: &state)
                }

                guard let active = state.current else {
                    write(buffers: buffers, frame: offset, left: 0, right: 0)
                    continue
                }
                let frame = state.framePosition % max(1, active.samples.count / 2)
                let left = active.samples[frame * 2]
                let right = active.samples[frame * 2 + 1]
                write(buffers: buffers, frame: offset, left: left, right: right)
                state.framePosition = (frame + 1) % loopFrameCountFor(active)
                state.beatPosition += deltaBeatFor(active)
            }
            return noErr
        }
    }

    private func adopt(_ candidate: Candidate, into state: inout State) {
        state.current = candidate.loop
        state.currentRevision = candidate.revision
        state.pending = nil
        state.pendingBoundary = nil
        state.framePosition = frame(for: state.beatPosition, in: candidate.loop)
    }

    private func frame(for beat: Double, in loop: PreparedLoop) -> Int {
        let localBeat = beat.truncatingRemainder(dividingBy: loop.beatCount)
        let ratio = max(0, min(1, localBeat / loop.beatCount))
        return Int((ratio * Double(loop.samples.count / 2)).rounded(.down)) % max(1, loop.samples.count / 2)
    }

    private func loopFrameCountFor(_ loop: PreparedLoop) -> Int {
        max(1, loop.samples.count / 2)
    }

    private func deltaBeatFor(_ loop: PreparedLoop) -> Double {
        loop.bpm / 60 / loop.sampleRate
    }

    private func write(buffers: UnsafeMutableAudioBufferListPointer, frame: Int, left: Float, right: Float) {
        for (index, buffer) in buffers.enumerated() {
            guard let data = buffer.mData else { continue }
            data.assumingMemoryBound(to: Float.self)[frame] = index == 0 ? left : right
        }
    }
}
