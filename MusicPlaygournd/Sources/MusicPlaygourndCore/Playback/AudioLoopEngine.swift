import AVFoundation
import Foundation
import Synchronization

@MainActor
public final class AudioLoopEngine {
    private let parameterSmoother: MasterParameterSmoother
    private let audioEngine: AVAudioEngine
    private let sourceNode: AVAudioSourceNode
    private let timePitch: AVAudioUnitTimePitch
    private let equalizer: AVAudioUnitEQ
    private let delay: AVAudioUnitDelay
    private let reverb: AVAudioUnitReverb
    private let transport: AudioTransport
    private let meterStore: OutputMeterStore
    private let audioFormat: AVAudioFormat
    private var retainedLoops: [UInt64: PreparedLoop] = [:]
    private var latestRequestedRevision: UInt64?

    public convenience init() throws {
        try self.init(parameterSmoother: MasterParameterSmoother())
    }

    internal init(parameterSmoother: MasterParameterSmoother) throws {
        self.parameterSmoother = parameterSmoother
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: PreparedLoop.requiredSampleRate,
            channels: 2
        ) else {
            throw PlaybackError.audioSetupFailed("Unable to create a 44.1 kHz stereo format.")
        }

        let transport = AudioTransport()
        let timePitch = AVAudioUnitTimePitch()
        let equalizer = AVAudioUnitEQ(numberOfBands: 1)
        let delay = AVAudioUnitDelay()
        let reverb = AVAudioUnitReverb()
        let meterStore = OutputMeterStore()

        let filter = equalizer.bands[0]
        filter.filterType = .lowPass
        filter.frequency = 1_000
        filter.bypass = true
        timePitch.rate = 1
        delay.delayTime = 0.25
        delay.feedback = 30
        delay.wetDryMix = 0
        reverb.loadFactoryPreset(.mediumRoom)
        reverb.wetDryMix = 0

        let sourceNode = AVAudioSourceNode(format: format) { @Sendable [transport] isSilence, _, frameCount, audioBufferList in
            let status = transport.render(frameCount: Int(frameCount), audioBufferList: audioBufferList)
            isSilence.pointee = ObjCBool(status != noErr)
            return status
        }
        let audioEngine = AVAudioEngine()
        audioEngine.attach(sourceNode)
        audioEngine.attach(timePitch)
        audioEngine.attach(equalizer)
        audioEngine.attach(delay)
        audioEngine.attach(reverb)
        audioEngine.connect(sourceNode, to: timePitch, format: format)
        audioEngine.connect(timePitch, to: equalizer, format: format)
        audioEngine.connect(equalizer, to: delay, format: format)
        audioEngine.connect(delay, to: reverb, format: format)
        audioEngine.connect(reverb, to: audioEngine.mainMixerNode, format: format)
        audioEngine.mainMixerNode.outputVolume = 1
        audioEngine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(OutputMeterStore.frameCapacity),
            format: nil
        ) { @Sendable [meterStore] buffer, _ in
            meterStore.capture(buffer)
        }
        self.transport = transport
        self.sourceNode = sourceNode
        self.timePitch = timePitch
        self.equalizer = equalizer
        self.delay = delay
        self.reverb = reverb
        self.meterStore = meterStore
        self.audioFormat = format
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
        meterStore.activate()
        do {
            if !audioEngine.isRunning {
                if !audioEngine.isInManualRenderingMode {
                    audioEngine.prepare()
                }
                try audioEngine.start()
            }
        } catch {
            transport.stopPlayback()
            audioEngine.stop()
            meterStore.clear()
            throw PlaybackError.audioStartFailed(String(describing: error))
        }
    }

    public func stop() {
        transport.stopPlayback()
        audioEngine.stop()
        parameterSmoother.finishAll()
        meterStore.clear()
        pruneRetainedLoops()
    }

    public func snapshot() -> PlaybackSnapshot {
        let position = transport.positionSnapshot()
        let rawSnapshot = position.playback
        pruneRetainedLoops(currentRevision: rawSnapshot.revision)
        guard rawSnapshot.isPlaying,
              let loop = rawSnapshot.loop else {
            return rawSnapshot
        }

        // The source node reports the complete downstream presentation latency.
        // Do not add individual effect latencies a second time. Unknown or invalid
        // metadata is excluded explicitly and leaves the transport position intact.
        let latency = sourceNode.outputPresentationLatency
        guard latency.isFinite, latency > 0 else { return rawSnapshot }
        let correction = latency * loop.bpm / 60 * Double(timePitch.rate)
        guard correction.isFinite, correction >= 0 else { return rawSnapshot }
        return PlaybackSnapshot(
            loop: rawSnapshot.loop,
            revision: rawSnapshot.revision,
            beatPosition: AudioTransport.correctedLocalBeatPosition(
                accumulatedBeatPosition: position.accumulatedBeatPosition,
                loopBeatCount: loop.beatCount,
                correction: correction
            ),
            isPlaying: rawSnapshot.isPlaying
        )
    }

    public func setPlaybackRate(_ rate: Float) throws {
        guard rate.isFinite, (1.0 / 32.0...32.0).contains(rate) else {
            throw PlaybackError.invalidPlaybackRate(rate)
        }
        let unit = timePitch
        parameterSmoother.set(.rate, from: unit.rate, to: rate,
                              immediate: !transport.snapshot().isPlaying) { value, _ in
            unit.rate = value
        }
    }

    public func setLowPass(cutoff: Float?) throws {
        if let cutoff, !cutoff.isFinite || !(20...20_000).contains(cutoff) {
            throw PlaybackError.invalidLowPassCutoff(cutoff)
        }
        let filter = equalizer.bands[0]
        let disabling = cutoff == nil
        let immediate = !transport.snapshot().isPlaying || (disabling && filter.bypass)
        if !disabling, filter.bypass {
            filter.frequency = 20_000
            filter.bypass = false
        }
        parameterSmoother.set(.lowPass, from: filter.frequency, to: cutoff ?? 20_000,
                              immediate: immediate) { value, final in
            filter.frequency = value
            filter.bypass = disabling && final
        }
    }

    public func setDelay(mix: Float) throws {
        guard mix.isFinite, (0...1).contains(mix) else {
            throw PlaybackError.invalidDelayMix(mix)
        }
        let unit = delay
        parameterSmoother.set(.delay, from: unit.wetDryMix / 100, to: mix,
                              immediate: !transport.snapshot().isPlaying) { value, _ in
            unit.wetDryMix = value * 100
        }
    }

    public func setReverb(mix: Float) throws {
        guard mix.isFinite, (0...1).contains(mix) else {
            throw PlaybackError.invalidReverbMix(mix)
        }
        let unit = reverb
        parameterSmoother.set(.reverb, from: unit.wetDryMix / 100, to: mix,
                              immediate: !transport.snapshot().isPlaying) { value, _ in
            unit.wetDryMix = value * 100
        }
    }

    internal var masterParametersForTests: (rate: Float, lowPass: Float?, delay: Float, reverb: Float) {
        let filter = equalizer.bands[0]
        return (timePitch.rate, filter.bypass ? nil : filter.frequency,
                delay.wetDryMix / 100, reverb.wetDryMix / 100)
    }

    public func outputMeter() -> OutputMeterSnapshot {
        if !transport.snapshot().isPlaying {
            meterStore.clear()
        }
        return meterStore.snapshot()
    }

    /// Enables native offline rendering for focused Core tests without changing the public app API.
    internal func prepareOfflineRenderingForTests() throws {
        guard !audioEngine.isInManualRenderingMode else { return }
        guard !audioEngine.isRunning else {
            throw PlaybackError.offlineRenderingFailed("The engine must be stopped before manual rendering setup.")
        }
        do {
            try audioEngine.enableManualRenderingMode(
                .offline,
                format: audioFormat,
                maximumFrameCount: AVAudioFrameCount(OutputMeterStore.frameCapacity * 2)
            )
        } catch {
            throw PlaybackError.offlineRenderingFailed(String(describing: error))
        }
    }

    /// Renders the native effect graph into a test-owned interleaved buffer.
    internal func renderOfflineForTests(frameCount: Int) throws -> [Float] {
        guard (1...(OutputMeterStore.frameCapacity * 2)).contains(frameCount) else {
            throw PlaybackError.offlineRenderingFailed("Offline frame count is outside the bounded test range.")
        }
        try prepareOfflineRenderingForTests()
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                throw PlaybackError.offlineRenderingFailed(String(describing: error))
            }
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw PlaybackError.offlineRenderingFailed("Unable to allocate the offline render buffer.")
        }
        do {
            let status = try audioEngine.renderOffline(AVAudioFrameCount(frameCount), to: buffer)
            guard status == .success else {
                throw PlaybackError.offlineRenderingFailed("Native renderer returned \(status).")
            }
        } catch let error as PlaybackError {
            throw error
        } catch {
            throw PlaybackError.offlineRenderingFailed(String(describing: error))
        }

        // AVAudioEngine does not invoke mixer taps for every offline configuration. The
        // returned buffer is the post-mixer render output, so use it to keep the test-only
        // monitor path tied to the same native effect graph when the tap is silent offline.
        meterStore.capture(buffer)

        let renderedFrames = min(Int(buffer.frameLength), frameCount)
        var output = [Float](repeating: 0, count: renderedFrames * 2)
        if audioFormat.isInterleaved {
            if let data = buffer.audioBufferList.pointee.mBuffers.mData {
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<renderedFrames {
                    output[frame * 2] = samples[frame * 2]
                    output[frame * 2 + 1] = samples[frame * 2 + 1]
                }
            }
        } else if let channels = buffer.floatChannelData {
            for frame in 0..<renderedFrames {
                output[frame * 2] = channels[0][frame]
                output[frame * 2 + 1] = channels[1][frame]
            }
        }
        return output
    }

    private func pruneRetainedLoops(currentRevision: UInt64? = nil) {
        let activeRevision = currentRevision ?? transport.snapshot().revision
        let retained = Set([activeRevision, latestRequestedRevision].compactMap { $0 })
        retainedLoops = retainedLoops.filter { retained.contains($0.key) }
    }

    isolated deinit {
        parameterSmoother.cancelAll()
        audioEngine.mainMixerNode.removeTap(onBus: 0)
        audioEngine.stop()
    }
}

// The callback crosses AVFAudio's render thread. Its only mutable field is Mutex-protected,
// and callback-local buffer borrows never escape this method.
final class AudioTransport: Sendable {
    struct PositionSnapshot {
        let playback: PlaybackSnapshot
        let accumulatedBeatPosition: Double
    }

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
        positionSnapshot().playback
    }

    func positionSnapshot() -> PositionSnapshot {
        state.withLock { state in
            let beatPosition: Double
            if let current = state.current {
                let frames = max(1, current.samples.count / 2)
                beatPosition = Double(state.framePosition) / Double(frames) * current.beatCount
            } else {
                beatPosition = 0
            }
            return PositionSnapshot(
                playback: PlaybackSnapshot(
                    loop: state.current,
                    revision: state.currentRevision,
                    beatPosition: beatPosition,
                    isPlaying: state.isPlaying
                ),
                accumulatedBeatPosition: state.beatPosition
            )
        }
    }

    static func correctedLocalBeatPosition(
        accumulatedBeatPosition: Double,
        loopBeatCount: Double,
        correction: Double
    ) -> Double {
        guard accumulatedBeatPosition.isFinite,
              loopBeatCount.isFinite, loopBeatCount > 0,
              correction.isFinite, correction >= 0 else {
            return 0
        }
        let corrected = accumulatedBeatPosition - correction
        guard corrected > 0 else { return 0 }
        let local = corrected.truncatingRemainder(dividingBy: loopBeatCount)
        return local >= 0 ? local : local + loopBeatCount
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
