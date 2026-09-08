import AVFoundation
import Foundation
import Synchronization

@MainActor
public final class AudioLoopEngine: AudioUnitHosting {
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
    private var retainedLoops: [AudioTransport.Identity: PreparedLoop] = [:]
    private var latestRequestedRevision: UInt64?

    private var hostedAudioUnit: AVAudioUnit?
    private var hostedAudioDescriptor: HostedAudioUnitDescriptor?
    private var audioUnitSelection = UUID()
    private var audioUnitRequest: AudioUnitInstantiation?
    internal var audioUnitStart: AudioUnitInstantiation.Start = AudioUnitInstantiation.nativeStart
    internal var audioUnitGraphStartCheck: (() throws -> Void)?

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

        let sourceNode = AVAudioSourceNode(format: format) { @Sendable [transport] isSilence, timestamp, frameCount, audioBufferList in
            let hostTime = timestamp.pointee.mFlags.contains(.hostTimeValid)
                ? timestamp.pointee.mHostTime : nil
            let status = transport.render(frameCount: Int(frameCount), audioBufferList: audioBufferList,
                                          hostTime: hostTime)
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
        retainedLoops[.init(revision: revision, generation: 0)] = loop
        pruneRetainedLoops()
    }

    /// Replaces adopted PCM without evaluating Swift or changing the musical clock.
    public func replace(loop: PreparedLoop, revision: UInt64, generation: UInt64) throws {
        do { try loop.validate() }
        catch let error as PreparedLoopValidationError { throw PlaybackError.invalidLoop(error) }
        pruneRetainedLoops()
        try transport.replace(loop: loop, revision: revision, generation: generation)
        retainedLoops[.init(revision: revision, generation: generation)] = loop
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

    public func restartFromBeginning() throws {
        try transport.restartFromBeginning()
        try play()
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
        pruneRetainedLoops()
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
            isPlaying: rawSnapshot.isPlaying,
            overrideGeneration: rawSnapshot.overrideGeneration
        )
    }

    public func playbackClockAnchor() throws -> PlaybackClockAnchor {
        try transport.clockAnchor(presentationLatency: sourceNode.outputPresentationLatency)
    }

    public func setPlaybackRate(_ rate: Float) throws {
        guard rate.isFinite, (1.0 / 32.0...32.0).contains(rate) else {
            throw PlaybackError.invalidPlaybackRate(rate)
        }
        let unit = timePitch
        let transport = transport
        parameterSmoother.set(.rate, from: unit.rate, to: rate,
                              immediate: !transport.snapshot().isPlaying) { value, _ in
            unit.rate = value
            transport.setClockRate(Double(value))
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

    public func discoverAudioEffects() throws -> [HostedAudioUnitDescriptor] {
        try AudioUnitCatalog.discover()
    }

    public func selectAudioEffect(_ id: HostedAudioUnitID, restoring state: HostedAudioUnitState? = nil) async throws {
        if let state, state.id != id { throw HostedAudioUnitError.stateIdentityMismatch }
        guard let descriptor = try discoverAudioEffects().first(where: { $0.id == id }) else {
            throw HostedAudioUnitError.missingComponent
        }
        audioUnitRequest?.cancel()
        let selection = UUID()
        audioUnitSelection = selection
        let request = AudioUnitInstantiation()
        audioUnitRequest = request
        defer { if audioUnitSelection == selection { audioUnitRequest = nil } }
        let candidate = try await request.value(for: id.componentDescription, start: audioUnitStart)
        try Task.checkCancellation()
        guard audioUnitSelection == selection else { throw HostedAudioUnitError.superseded }
        let nativeID = candidate.audioComponentDescription
        guard nativeID.componentType == id.componentType,
              nativeID.componentSubType == id.componentSubType,
              nativeID.componentManufacturer == id.componentManufacturer else {
            throw HostedAudioUnitError.instantiationFailed("The native component identity did not match the selection.")
        }
        let unit = candidate.auAudioUnit
        if let state { unit.fullStateForDocument = try state.propertyList() }
        guard unit.inputBusses.count > 0, unit.outputBusses.count > 0 else {
            throw HostedAudioUnitError.incompatibleFormat("An input and an output bus are required.")
        }
        guard unit.latency.isFinite, unit.latency >= 0, unit.tailTime.isFinite, unit.tailTime >= 0 else {
            throw HostedAudioUnitError.invalidLatency
        }
        do {
            try unit.inputBusses[0].setFormat(audioFormat)
            try unit.outputBusses[0].setFormat(audioFormat)
        } catch { throw HostedAudioUnitError.incompatibleFormat(error.localizedDescription) }
        try swapAudioEffect(candidate)
        hostedAudioDescriptor = descriptor
    }

    public func clearAudioEffect() throws {
        audioUnitSelection = UUID()
        audioUnitRequest?.cancel()
        audioUnitRequest = nil
        guard hostedAudioUnit != nil else { return }
        try swapAudioEffect(nil)
        hostedAudioDescriptor = nil
    }

    public func setAudioEffectBypassed(_ bypassed: Bool) throws {
        guard let unit = hostedAudioUnit else { throw HostedAudioUnitError.notLoaded }
        unit.auAudioUnit.shouldBypassEffect = bypassed
        transport.invalidateClock()
    }

    public func captureAudioEffectState() throws -> HostedAudioUnitState {
        guard let unit = hostedAudioUnit, let descriptor = hostedAudioDescriptor else {
            throw HostedAudioUnitError.notLoaded
        }
        return try HostedAudioUnitState(id: descriptor.id, documentState: unit.auAudioUnit.fullStateForDocument)
    }

    public func audioEffectSnapshot() -> HostedAudioUnitSnapshot {
        guard let unit = hostedAudioUnit, let descriptor = hostedAudioDescriptor else { return .none }
        return .loaded(descriptor: descriptor, bypassed: unit.auAudioUnit.shouldBypassEffect)
    }

    private func swapAudioEffect(_ candidate: AVAudioUnit?) throws {
        let previous = hostedAudioUnit
        let wasRunning = audioEngine.isRunning
        audioEngine.stop()
        transport.invalidateClock()
        audioEngine.disconnectNodeOutput(reverb)
        if let previous { audioEngine.disconnectNodeOutput(previous) }
        if let candidate { audioEngine.attach(candidate) }
        connectAudioEffect(candidate)
        do {
            if wasRunning {
                try audioUnitGraphStartCheck?()
                if !audioEngine.isInManualRenderingMode { audioEngine.prepare() }
                try audioEngine.start()
            }
        } catch {
            audioEngine.stop()
            audioEngine.disconnectNodeOutput(reverb)
            if let candidate { audioEngine.detach(candidate) }
            connectAudioEffect(previous)
            do {
                if wasRunning {
                    try audioUnitGraphStartCheck?()
                    if !audioEngine.isInManualRenderingMode { audioEngine.prepare() }
                    try audioEngine.start()
                }
            } catch let rollback {
                transport.stopPlayback()
                meterStore.clear()
                throw HostedAudioUnitError.rollbackFailed(error.localizedDescription, rollback.localizedDescription)
            }
            throw HostedAudioUnitError.graphFailed(error.localizedDescription)
        }
        if let previous { audioEngine.detach(previous) }
        hostedAudioUnit = candidate
    }

    private func connectAudioEffect(_ unit: AVAudioUnit?) {
        // Bus formats and node ownership are admitted before these native precondition operations.
        if let unit {
            audioEngine.connect(reverb, to: unit, format: audioFormat)
            audioEngine.connect(unit, to: audioEngine.mainMixerNode, format: audioFormat)
        } else {
            audioEngine.connect(reverb, to: audioEngine.mainMixerNode, format: audioFormat)
        }
    }

    private func pruneRetainedLoops() {
        let retained = Set(transport.drainRetiredAndRetainedIdentities())
        retainedLoops = retainedLoops.filter { retained.contains($0.key) }
    }

    isolated deinit {
        audioUnitRequest?.cancel()
        parameterSmoother.cancelAll()
        audioEngine.mainMixerNode.removeTap(onBus: 0)
        audioEngine.stop()
        if let hostedAudioUnit { audioEngine.detach(hostedAudioUnit) }
    }
}

// The callback crosses AVFAudio's render thread. Its only mutable field is Mutex-protected,
// and callback-local buffer borrows never escape this method.
final class AudioTransport: Sendable {
    struct Identity: Sendable, Hashable {
        let revision: UInt64
        let generation: UInt64
    }

    static let crossfadeFrames = 1_323

    struct PositionSnapshot {
        let playback: PlaybackSnapshot
        let accumulatedBeatPosition: Double
    }

    private struct Candidate: Sendable {
        let loop: PreparedLoop
        let revision: UInt64
        var generation: UInt64 = 0
        var identity: Identity { Identity(revision: revision, generation: generation) }
    }

    private struct Fade: Sendable {
        let old: Candidate
        var elapsed = 0
    }

    private struct ClockSample: Sendable {
        let hostTime: UInt64
        let beat: Double
    }

    private struct State: Sendable {
        var current: PreparedLoop?
        var currentRevision: UInt64?
        var currentGeneration: UInt64 = 0
        var latestGeneration: UInt64 = 0
        var replacement: Candidate?
        var fade: Fade?
        var retired: Candidate?
        var pending: Candidate?
        var latestRevision: UInt64?
        var submittedRevision: UInt64?
        var beatPosition = 0.0
        var framePosition = 0
        var pendingBoundary: Double?
        var isPlaying = false
        var clockSample: ClockSample?
        var lastHostTime: UInt64?
        var clockDiscontinuous = false
        var clockRate = 1.0
    }

    private let state = Mutex(State())

    /// Called only off callback. The engine keeps every returned immutable buffer alive.
    func drainRetiredAndRetainedIdentities() -> [Identity] {
        state.withLock { state in
            state.retired = nil
            var identities: [Identity] = []
            if let revision = state.currentRevision {
                identities.append(Identity(revision: revision, generation: state.currentGeneration))
            }
            if let pending = state.pending { identities.append(pending.identity) }
            if let replacement = state.replacement { identities.append(replacement.identity) }
            if let fade = state.fade { identities.append(fade.old.identity) }
            return identities
        }
    }

    func replace(loop: PreparedLoop, revision: UInt64, generation: UInt64) throws {
        try state.withLock { state in
            guard state.currentRevision == revision, let current = state.current else {
                throw PlaybackError.staleRevision(revision)
            }
            guard generation > state.latestGeneration else {
                throw PlaybackError.staleOverrideGeneration(generation)
            }
            guard Self.sameShape(current, loop) else { throw PlaybackError.incompatibleReplacement }
            state.latestGeneration = generation
            let candidate = Candidate(loop: loop, revision: revision, generation: generation)
            if !state.isPlaying {
                state.current = loop
                state.currentGeneration = generation
                state.clockSample = nil
                state.fade = nil
                state.retired = nil
                state.replacement = nil
            } else if state.fade == nil, state.retired == nil {
                beginFade(candidate, into: &state)
            } else {
                state.replacement = candidate
            }
        }
    }

    private static func sameShape(_ lhs: PreparedLoop, _ rhs: PreparedLoop) -> Bool {
        guard lhs.sampleRate == rhs.sampleRate, lhs.bpm == rhs.bpm,
              lhs.beatsPerBar == rhs.beatsPerBar, lhs.beatCount == rhs.beatCount,
              lhs.samples.count == rhs.samples.count,
              lhs.events.count == rhs.events.count, lhs.rows.count == rhs.rows.count else { return false }
        for (a, b) in zip(lhs.events, rhs.events) {
            guard a.sourceID == b.sourceID, a.label == b.label, a.startBeat == b.startBeat,
                  a.velocity == b.velocity, a.patternStepIndex == b.patternStepIndex else { return false }
        }
        for (a, b) in zip(lhs.rows, rhs.rows) {
            guard a.sourceID == b.sourceID, a.label == b.label, a.anchor == b.anchor,
                  a.patternText == b.patternText, a.resultLine == b.resultLine else { return false }
        }
        return true
    }

    private func beginFade(_ candidate: Candidate, into state: inout State) {
        guard let current = state.current, let revision = state.currentRevision else { return }
        state.fade = Fade(old: Candidate(loop: current, revision: revision, generation: state.currentGeneration))
        state.current = candidate.loop
        state.currentGeneration = candidate.generation
        state.clockSample = nil
        state.replacement = nil
    }

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
            if !state.isPlaying {
                state.clockSample = nil
                state.lastHostTime = nil
                state.clockDiscontinuous = false
            }
            state.isPlaying = true
        }
    }

    func restartFromBeginning() throws {
        try state.withLock { state in
            guard let current = state.current else { throw PlaybackError.noCurrentLoop }
            state.framePosition = 0
            state.beatPosition = 0
            state.clockSample = nil
            state.lastHostTime = nil
            state.clockDiscontinuous = false
            state.pendingBoundary = state.pending == nil ? nil : Double(current.beatsPerBar)
            state.isPlaying = true
        }
    }

    func stopPlayback() {
        state.withLock { state in
            state.isPlaying = false
            state.clockSample = nil
            if let replacement = state.replacement {
                state.current = replacement.loop
                state.currentGeneration = replacement.generation
            }
            state.replacement = nil
            state.fade = nil
            state.retired = nil
        }
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
                    isPlaying: state.isPlaying,
                    overrideGeneration: state.currentGeneration
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

    func invalidateClock() {
        state.withLock { $0.clockSample = nil }
    }

    func setClockRate(_ rate: Double) {
        state.withLock { state in
            if state.clockRate != rate {
                state.clockRate = rate
                state.clockSample = nil
            }
        }
    }

    func clockAnchor(presentationLatency: Double, now: UInt64 = mach_absolute_time()) throws -> PlaybackClockAnchor {
        let values = state.withLock { state in
            (state.current?.bpm, state.current?.beatCount, state.currentRevision,
             state.currentGeneration, state.isPlaying, state.beatPosition, state.clockRate,
             state.clockSample, state.clockDiscontinuous)
        }
        guard let bpm = values.0, let count = values.1, let revision = values.2 else {
            throw PlaybackClockError.unavailable
        }
        if !values.4 {
            return try PlaybackClockAnchor(presentationHostTime: now, accumulatedBeatPosition: values.5,
                beatsPerMinute: bpm * values.6, loopBeatCount: count, revision: revision,
                overrideGeneration: values.3, isPlaying: false)
        }
        guard !values.8 else { throw PlaybackClockError.discontinuous }
        guard let sample = values.7 else { throw PlaybackClockError.unavailable }
        let latency = try PlaybackClockAnchor.hostTicks(forSeconds: presentationLatency)
        let (host, overflow) = sample.hostTime.addingReportingOverflow(latency)
        guard !overflow else { throw PlaybackClockError.outOfRange }
        return try PlaybackClockAnchor(presentationHostTime: host, accumulatedBeatPosition: sample.beat,
            beatsPerMinute: bpm * values.6, loopBeatCount: count, revision: revision,
            overrideGeneration: values.3, isPlaying: true)
    }

    func render(frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>,
                hostTime: UInt64? = nil) -> OSStatus {
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

            if let hostTime, hostTime > 0 {
                state.clockDiscontinuous = state.lastHostTime.map { hostTime <= $0 } ?? false
                state.clockSample = state.clockDiscontinuous ? nil
                    : ClockSample(hostTime: hostTime, beat: state.beatPosition)
                state.lastHostTime = hostTime
            } else {
                state.clockSample = nil
            }
            for offset in 0..<frameCount {
                if let pending = state.pending,
                   let boundary = state.pendingBoundary,
                   state.beatPosition >= boundary {
                    adopt(pending, into: &state)
                }

                if state.fade == nil, state.retired == nil, let replacement = state.replacement {
                    beginFade(replacement, into: &state)
                }

                guard let active = state.current else {
                    write(buffers: buffers, frame: offset, left: 0, right: 0)
                    continue
                }
                let frame = state.framePosition % max(1, active.samples.count / 2)
                var left = active.samples[frame * 2]
                var right = active.samples[frame * 2 + 1]
                if let fade = state.fade {
                    let mix = Float(fade.elapsed) / Float(Self.crossfadeFrames - 1)
                    left = fade.old.loop.samples[frame * 2] * (1 - mix) + left * mix
                    right = fade.old.loop.samples[frame * 2 + 1] * (1 - mix) + right * mix
                    if fade.elapsed + 1 == Self.crossfadeFrames {
                        state.retired = fade.old
                        state.fade = nil
                    } else {
                        state.fade?.elapsed += 1
                    }
                }
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
        state.clockSample = nil
        state.currentGeneration = 0
        state.latestGeneration = 0
        state.replacement = nil
        if let fade = state.fade { state.retired = fade.old }
        state.fade = nil
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
