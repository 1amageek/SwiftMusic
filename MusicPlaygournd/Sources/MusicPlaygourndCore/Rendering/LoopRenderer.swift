import Foundation
import SwiftMusic

public struct LoopRenderer: Sendable {
    private let sampleLoader: any SampleLoading

    public init(sampleLoader: any SampleLoading = AVAudioFileSampleLoader()) {
        self.sampleLoader = sampleLoader
    }

    public func render(
        _ sound: CompiledSound,
        bpm: Double,
        beatsPerBar: Int
    ) throws -> PreparedLoop {
        guard bpm.isFinite, (40...240).contains(bpm) else {
            throw LoopRenderingError.invalidBPM(bpm)
        }
        guard (2...7).contains(beatsPerBar) else {
            throw LoopRenderingError.invalidMeter(beatsPerBar)
        }
        guard sound.sources.count <= 32 else {
            throw LoopRenderingError.tooManySources(limit: 32)
        }
        guard sound.events.count <= 1_024 else {
            throw LoopRenderingError.tooManyEvents(limit: 1_024)
        }
        guard sound.renderNodes.count <= 256 else {
            throw LoopRenderingError.tooManyRenderNodes(limit: 256)
        }

        var extent = try beatValue(sound.extent)
        guard extent.isFinite, extent >= 0 else {
            throw LoopRenderingError.invalidSound("non-finite extent")
        }
        guard extent <= PreparedLoop.maximumBeatCount else {
            throw LoopRenderingError.extentTooLong(extent)
        }

        let preparedSamples = try SamplePreparation(sound: sound, loader: sampleLoader)
        var sampleFrames: [Int: Int] = [:]
        let maximumSeconds = min(PreparedLoop.maximumDurationSeconds, PreparedLoop.maximumBeatCount * 60 / bpm)
        for (index, voice) in preparedSamples.voices {
            let event = sound.events[index]
            let source = sound.sources[event.sourceID]
            let available = sound.playbackMode == .seamlessLoop ? extent * 60 / bpm
                : max(0, maximumSeconds - (try beatValue(event.start)) * 60 / bpm)
            let frames = try voice.frames(event: event, source: source, secondsPerBeat: 60 / bpm,
                                          limit: Int((available * PreparedLoop.requiredSampleRate).rounded(.down)))
            sampleFrames[index] = frames
            if sound.playbackMode == .finite {
                extent = max(extent, try beatValue(event.start) + Double(frames) / PreparedLoop.requiredSampleRate * bpm / 60)
            }
        }
        for (index, event) in sound.events.enumerated() {
            guard sound.sources.indices.contains(event.sourceID) else {
                throw LoopRenderingError.invalidEvent(index: index, reason: "source ID is out of range")
            }
            if sampleFrames[index] == nil, let envelope = VoiceEnvelope.amplitude(event: event, source: sound.sources[event.sourceID],
                                                       secondsPerBeat: 60 / bpm) {
                let span = envelope.duration * bpm / 60
                guard span.isFinite, span > 0 else {
                    throw LoopRenderingError.invalidEvent(index: index, reason: "invalid envelope release horizon")
                }
                if sound.playbackMode == .finite {
                    extent = max(extent, try beatValue(event.start) + span)
                    guard extent <= PreparedLoop.maximumBeatCount else {
                        throw LoopRenderingError.extentTooLong(extent)
                    }
                } else if span > extent {
                    throw LoopRenderingError.invalidEvent(index: index, reason: "envelope release exceeds loop window")
                }
            }
        }
        let bars = max(1, Int(ceil(extent / Double(beatsPerBar))))
        var beatCount = Double(bars * beatsPerBar)
        guard beatCount <= PreparedLoop.maximumBeatCount else {
            throw LoopRenderingError.extentTooLong(beatCount)
        }
        if sound.playbackMode == .seamlessLoop, beatCount != extent {
            throw LoopRenderingError.invalidSound(
                "Seamless loop extent must align with the requested meter"
            )
        }
        let duration = beatCount * 60 / bpm
        guard duration.isFinite, duration <= PreparedLoop.maximumDurationSeconds else {
            throw LoopRenderingError.durationTooLong(duration)
        }
        var frameCount = try frameCount(for: duration)

        var context = try RenderContext(
            sound: sound,
            bpm: bpm,
            beatCount: beatCount,
            frameCount: frameCount,
            preparedSamples: preparedSamples,
            sampleFrames: sampleFrames
        )
        let sourceBeatCount = beatCount
        try context.prepareEffects(beatsPerBar: beatsPerBar)
        beatCount = context.beatCount
        frameCount = context.frameCount
        var output = try context.renderRoots()
        output.clamp(to: -1...1)

        var samples = output.interleaved
        samples.reserveCapacity(frameCount * 2)
        let events = try sound.events.enumerated().map { index, event in
            guard event.sourceID >= 0, event.sourceID < sound.sources.count else {
                throw LoopRenderingError.invalidEvent(index: index, reason: "source ID is out of range")
            }
            let source = sound.sources[event.sourceID]
            let startBeat = try beatValue(event.start)
            let durationBeats = try beatValue(event.duration)
            let fullDuration = sampleFrames[index].map { Double($0) / PreparedLoop.requiredSampleRate * bpm / 60 }
                ?? VoiceEnvelope.amplitude(event: event, source: source, secondsPerBeat: 60 / bpm)
                    .map { $0.duration * bpm / 60 } ?? durationBeats * event.gate
            let audibleDuration: Double
            let wrapsLoopBoundary: Bool
            if sound.playbackMode == .seamlessLoop {
                let gatedDuration = fullDuration
                guard gatedDuration.isFinite, gatedDuration > 0, gatedDuration <= beatCount else {
                    throw LoopRenderingError.invalidEvent(
                        index: index,
                        reason: "seamless event duration exceeds loop window"
                    )
                }
                audibleDuration = gatedDuration
                wrapsLoopBoundary = startBeat + gatedDuration > beatCount
            } else {
                audibleDuration = min(
                    fullDuration,
                    max(0, sourceBeatCount - startBeat)
                )
                wrapsLoopBoundary = false
            }
            guard audibleDuration > 0 else {
                throw LoopRenderingError.invalidEvent(index: index, reason: "event has no audible duration")
            }
            let label: String
            if let trackID = event.trackID {
                guard let track = sound.tracks.first(where: { $0.id == trackID }) else {
                    throw LoopRenderingError.invalidEvent(index: index, reason: "track ID is out of range")
                }
                label = track.name
            } else {
                label = self.label(for: source.kind)
            }
            return LoopEvent(
                sourceID: event.sourceID,
                label: label,
                startBeat: startBeat,
                durationBeats: audibleDuration,
                midiNote: event.pitch.map { Int($0.midiNote) },
                velocity: event.velocity,
                patternStepIndex: event.patternStepIndex,
                gain: event.gain,
                pan: event.pan,
                wrapsLoopBoundary: wrapsLoopBoundary
            )
        }
        let rows = sound.sources.enumerated().map { index, source in
            LoopRow(
                sourceID: source.id,
                label: self.label(for: source.id, in: sound),
                anchor: source.patternAnchor,
                peaks: context.sourcePeakEnvelopes[index],
                patternText: source.patternText
            )
        }

        let prepared = PreparedLoop(
            sampleRate: PreparedLoop.requiredSampleRate,
            bpm: bpm,
            beatsPerBar: beatsPerBar,
            beatCount: beatCount,
            samples: samples,
            events: events,
            rows: rows
        )
        do {
            try prepared.validate()
        } catch let error as PreparedLoopValidationError {
            throw LoopRenderingError.invalidPreparedLoop(error)
        }
        return prepared
    }

    private func frameCount(for duration: Double) throws -> Int {
        let frames = duration * PreparedLoop.requiredSampleRate
        guard frames.isFinite, frames >= 1, frames <= PreparedLoop.maximumDurationSeconds * PreparedLoop.requiredSampleRate else {
            throw LoopRenderingError.durationTooLong(duration)
        }
        let rounded = frames.rounded(.up)
        guard rounded <= Double(Int.max) else { throw LoopRenderingError.overflow }
        return max(1, Int(rounded))
    }

    private func beatValue(_ time: MusicalTime) throws -> Double {
        let value = Double(time.numerator) / Double(time.denominator)
        guard value.isFinite else { throw LoopRenderingError.overflow }
        return value
    }

    private func label(for kind: SourceKind) -> String {
        switch kind {
        case .sample(let name): name
        case .fileSample(let url, _): url.lastPathComponent
        case .sampleBank: "Sample bank"
        case .synthesizer(let waveform):
            switch waveform {
            case .sine: "sine"
            case .square: "square"
            case .saw: "saw"
            case .triangle: "triangle"
            case .noise: "noise"
            }
        }
    }

    private func label(for sourceID: Int, in sound: CompiledSound) -> String {
        guard let source = sound.sources.first(where: { $0.id == sourceID }) else {
            return "source \(sourceID)"
        }
        if let event = sound.events.first(where: { $0.sourceID == sourceID }),
           let trackID = event.trackID,
           let track = sound.tracks.first(where: { $0.id == trackID }) {
            return track.name
        }
        return label(for: source.kind)
    }
}

internal struct StereoBuffer: Sendable {
    var left: [Float]
    var right: [Float]

    init(frameCount: Int, repeating value: Float = 0) {
        left = Array(repeating: value, count: frameCount)
        right = Array(repeating: value, count: frameCount)
    }

    mutating func add(_ other: Self) {
        for index in left.indices {
            left[index] += other.left[index]
            right[index] += other.right[index]
        }
    }

    mutating func multiply(by gain: Float) {
        for index in left.indices {
            left[index] *= gain
            right[index] *= gain
        }
    }

    mutating func applyPan(_ pan: Double) {
        let angle = (pan + 1) * .pi / 4
        let leftGain = Float(cos(angle))
        let rightGain = Float(sin(angle))
        for index in left.indices {
            left[index] *= leftGain
            right[index] *= rightGain
        }
    }

    mutating func mute() {
        left = Array(repeating: 0, count: left.count)
        right = Array(repeating: 0, count: right.count)
    }

    mutating func clamp(to range: ClosedRange<Float>) {
        for index in left.indices {
            left[index] = min(max(left[index], range.lowerBound), range.upperBound)
            right[index] = min(max(right[index], range.lowerBound), range.upperBound)
        }
    }

    var interleaved: [Float] {
        var result = [Float]()
        result.reserveCapacity(left.count * 2)
        for index in left.indices {
            result.append(left[index])
            result.append(right[index])
        }
        return result
    }
}

private struct RenderContext {
    let sound: CompiledSound
    let bpm: Double
    var beatCount: Double
    var frameCount: Int
    let sourceBeatCount: Double
    let sourceFrameCount: Int
    var nodeHorizons: [Int] = []
    var convolver: FFTConvolver?
    let secondsPerBeat: Double
    var nodeStates: [UInt8]
    var sourcePeakEnvelopes: [[Float]]
    let preparedSamples: SamplePreparation
    let sampleFrames: [Int: Int]
    var scheduledSources: [StereoBuffer]?

    init(sound: CompiledSound, bpm: Double, beatCount: Double, frameCount: Int,
         preparedSamples: SamplePreparation, sampleFrames: [Int: Int]) throws {
        self.preparedSamples = preparedSamples
        self.sampleFrames = sampleFrames
        self.sound = sound
        self.bpm = bpm
        self.sourceBeatCount = beatCount
        self.sourceFrameCount = frameCount
        self.beatCount = beatCount
        self.frameCount = frameCount
        self.secondsPerBeat = 60 / bpm
        self.nodeStates = Array(repeating: 0, count: sound.renderNodes.count)
        self.sourcePeakEnvelopes = Array(
            repeating: [Float](repeating: 0, count: 1),
            count: sound.sources.count
        )

        for event in sound.events {
            let source = sound.sources[event.sourceID]
            guard (event.cutoffHz != nil) == (source.filter != nil) else {
                throw LoopRenderingError.invalidSound("source filter and event cutoff must be paired")
            }
        }
        for source in sound.sources {
            if case .synthesizer(.noise) = source.kind,
               source.tuning != nil || source.pitchEnvelope != nil || sound.events.contains(where: {
                   $0.sourceID == source.id && $0.pitchOffsetSemitones != 0
               }) {
                throw LoopRenderingError.unsupportedSourceSetting(sourceID: source.id, setting: "white noise has no pitched oscillator")
            }
            if source.filterEnvelope != nil, source.filter == nil {
                throw LoopRenderingError.unsupportedSourceSetting(sourceID: source.id, setting: "filterEnvelope requires a source filter")
            }
            // Procedural samples have no decoded asset or root pitch; rooted file/bank sources support pitch traversal.
            if case .sample = source.kind,
               source.tuning != nil || source.pitchEnvelope != nil || sound.events.contains(where: {
                   $0.sourceID == source.id && $0.pitchOffsetSemitones != 0
               }) {
                throw LoopRenderingError.unsupportedSourceSetting(sourceID: source.id, setting: "sample pitch traversal")
            }
            // FIXME(INCOMPLETE_IMPLEMENTATION): unison rendering is unavailable in editor evaluation; require PCM behavior tests before enabling it.
            guard source.unison == nil else {
                throw LoopRenderingError.unsupportedSourceSetting(sourceID: source.id, setting: "unison")
            }
            switch source.kind {
            case .sample(let name) where ["kick", "snare", "closedHat"].contains(name):
                break
            case .sample(let name):
                throw LoopRenderingError.unsupportedSource(sourceID: source.id, kind: "sample(\(name))")
            case .synthesizer, .fileSample, .sampleBank:
                break
            }
        }
    }

    mutating func prepareEffects(beatsPerBar: Int) throws {
        guard sound.renderNodes.contains(where: { if case .effect = $0 { true } else { false } }) else { return }
        let seamless = sound.playbackMode == .seamlessLoop
        var sources = [Int](repeating: 0, count: sound.sources.count)
        for index in sound.events.indices {
            let voice = try makeVoice(index)
            sources[sound.events[index].sourceID] = max(sources[sound.events[index].sourceID], voice.startFrame + voice.eventFrames)
        }
        var maximumImpulse = 0
        for (index, node) in sound.renderNodes.enumerated() {
            func horizon(_ input: Int) throws -> Int {
                guard input >= 0, input < index else { throw LoopRenderingError.invalidSound("render nodes must be dependency ordered") }
                return nodeHorizons[input]
            }
            let value: Int
            switch node {
            case .source(let source):
                guard sources.indices.contains(source) else { throw LoopRenderingError.invalidSound("source node ID is out of range") }
                value = sources[source]
            case .mix(let inputs): value = try inputs.reduce(0) { max($0, try horizon($1)) }
            case .gain(let input, _), .pan(let input, _), .mute(let input): value = try horizon(input)
            case .effect(let input, let effect):
                let tail = try EffectProcessor.tailFrames(effect, bpm: bpm, node: index)
                value = try horizon(input) + tail
                switch effect {
                case .reverb(_, let wet), .delay(_, _, let wet):
                    if wet != 0 { maximumImpulse = max(maximumImpulse, tail + 1) }
                default: break
                }
            case .send, .output: throw LoopRenderingError.unsupportedRenderNode(index: index, operation: "routing")
            }
            if !seamless, value > EffectProcessor.maximumTailFrames {
                throw LoopRenderingError.durationTooLong(Double(value) / PreparedLoop.requiredSampleRate)
            }
            nodeHorizons.append(seamless ? sourceFrameCount : value)
        }
        if !seamless {
            var end = sourceFrameCount
            for root in sound.rootNodeIDs {
                guard nodeHorizons.indices.contains(root) else { throw LoopRenderingError.invalidSound("root node ID is out of range") }
                end = max(end, nodeHorizons[root])
            }
            if end > sourceFrameCount {
                let beats = Double(end) / PreparedLoop.requiredSampleRate / secondsPerBeat
                beatCount = ceil(beats / Double(beatsPerBar)) * Double(beatsPerBar)
            }
            guard beatCount <= PreparedLoop.maximumBeatCount else { throw LoopRenderingError.extentTooLong(beatCount) }
            let seconds = beatCount * secondsPerBeat
            guard seconds <= PreparedLoop.maximumDurationSeconds else { throw LoopRenderingError.durationTooLong(seconds) }
            frameCount = Int((seconds * PreparedLoop.requiredSampleRate).rounded(.up))
        }
        if maximumImpulse > 0 {
            convolver = try FFTConvolver(maximumLinearFrameCount: frameCount + maximumImpulse - 1)
        }
    }

    mutating func renderRoots() throws -> StereoBuffer {
        if sound.sources.contains(where: { $0.voicePolicy != nil || $0.chokeGroup != nil }) {
            scheduledSources = try VoiceScheduler.render(
                templates: sound.events.indices.map { try makeVoice($0) },
                sourceCount: sound.sources.count, frameCount: frameCount,
                seamless: sound.playbackMode == .seamlessLoop)
        }
        var output = StereoBuffer(frameCount: frameCount)
        for rootID in sound.rootNodeIDs {
            guard rootID >= 0, rootID < sound.renderNodes.count else {
                throw LoopRenderingError.invalidSound("root node ID is out of range")
            }
            var root = try renderNode(rootID)
            output.add(root)
            root.left.removeAll(keepingCapacity: false)
            root.right.removeAll(keepingCapacity: false)
        }
        return output
    }

    private mutating func renderNode(_ nodeID: Int) throws -> StereoBuffer {
        guard nodeID >= 0, nodeID < sound.renderNodes.count else {
            throw LoopRenderingError.invalidSound("node ID is out of range")
        }
        guard nodeStates[nodeID] != 1 else {
            throw LoopRenderingError.invalidSound("render graph contains a cycle")
        }
        nodeStates[nodeID] = 1
        defer { nodeStates[nodeID] = 2 }

        switch sound.renderNodes[nodeID] {
        case .source(let sourceID):
            guard sourceID >= 0, sourceID < sound.sources.count else {
                throw LoopRenderingError.invalidSound("source node ID is out of range")
            }
            return try renderSource(sourceID)
        case .mix(let inputs):
            var output = StereoBuffer(frameCount: frameCount)
            for input in inputs {
                var child = try renderNode(input)
                output.add(child)
                child.left.removeAll(keepingCapacity: false)
                child.right.removeAll(keepingCapacity: false)
            }
            return output
        case .gain(let input, let value):
            guard value.isFinite, value >= 0 else {
                throw LoopRenderingError.invalidSound("gain is invalid")
            }
            var output = try renderNode(input)
            output.multiply(by: Float(value))
            return output
        case .pan(let input, let value):
            guard value.isFinite, (-1...1).contains(value) else {
                throw LoopRenderingError.invalidSound("pan is invalid")
            }
            var output = try renderNode(input)
            output.applyPan(value)
            return output
        case .mute(let input):
            var output = try renderNode(input)
            output.mute()
            return output
        case .effect(let input, let effect):
            var output = try renderNode(input)
            try EffectProcessor.apply(effect, to: &output, inputHorizon: nodeHorizons[input],
                                      bpm: bpm, seamless: sound.playbackMode == .seamlessLoop,
                                      node: nodeID, convolver: convolver)
            return output
        // FIXME(INCOMPLETE_IMPLEMENTATION): send processing is unavailable in editor evaluation; require DSP/routing behavior tests before enabling it.
        case .send:
            throw LoopRenderingError.unsupportedRenderNode(index: nodeID, operation: "send")
        // FIXME(INCOMPLETE_IMPLEMENTATION): output processing is unavailable in editor evaluation; require DSP/routing behavior tests before enabling it.
        case .output:
            throw LoopRenderingError.unsupportedRenderNode(index: nodeID, operation: "output")
        }
    }

    private mutating func renderSource(_ sourceID: Int) throws -> StereoBuffer {
        if let scheduledSources {
            let output = scheduledSources[sourceID]
            sourcePeakEnvelopes[sourceID] = peakEnvelope(for: output)
            return output
        }
        var output = StereoBuffer(frameCount: frameCount)
        for eventIndex in sound.events.indices where sound.events[eventIndex].sourceID == sourceID {
            var voice = try makeVoice(eventIndex)
            for offset in 0..<voice.eventFrames {
                let frame = sound.playbackMode == .seamlessLoop
                    ? (voice.startFrame + offset) % frameCount : voice.startFrame + offset
                let value = try voice.next()
                output.left[frame] += value.left
                output.right[frame] += value.right
            }
        }
        sourcePeakEnvelopes[sourceID] = peakEnvelope(for: output)
        return output
    }

    private func peakEnvelope(for buffer: StereoBuffer) -> [Float] {
        let frameCount = buffer.left.count
        let binCount = min(PreparedLoop.maximumPeakBins, max(1, frameCount))
        var envelope = [Float](repeating: 0, count: binCount)
        for bin in 0..<binCount {
            let start = bin * frameCount / binCount
            let end = max(start + 1, (bin + 1) * frameCount / binCount)
            var peak: Float = 0
            for frame in start..<min(end, frameCount) {
                peak = max(peak, abs(buffer.left[frame]), abs(buffer.right[frame]))
            }
            envelope[bin] = peak
        }
        return envelope
    }

    private func makeVoice(_ eventIndex: Int) throws -> RenderedVoice {
        let event = sound.events[eventIndex]
        let source = sound.sources[event.sourceID]
        let startBeat = try beatValue(event.start)
        let durationBeats = try beatValue(event.duration)
        guard event.velocity >= 1, event.velocity <= 127 else {
            throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "velocity is out of range")
        }
        guard event.gate.isFinite, event.gate > 0 else {
            throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "gate is invalid")
        }
        let seamless = sound.playbackMode == .seamlessLoop
        guard startBeat >= 0,
              seamless ? startBeat < sourceBeatCount : startBeat < sourceBeatCount + 1e-9 else {
            throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "start is outside loop")
        }
        let startFrame = max(0, min(sourceFrameCount, Int((startBeat * secondsPerBeat * PreparedLoop.requiredSampleRate).rounded(.down))))
        if seamless {
            guard startFrame < sourceFrameCount else {
                throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "start is outside loop frames")
            }
        }
        let naturalDuration = durationBeats * secondsPerBeat
        let amplitudeEnvelope = VoiceEnvelope.amplitude(event: event, source: source,
                                                         secondsPerBeat: secondsPerBeat)
        let sampleVoice = preparedSamples.voices[eventIndex]
        let fullDuration = sampleFrames[eventIndex].map { Double($0) / PreparedLoop.requiredSampleRate }
            ?? amplitudeEnvelope?.duration ?? naturalDuration * event.gate
        let eventFrames: Int
        if let count = sampleFrames[eventIndex] {
            guard count > 0, count <= (seamless ? sourceFrameCount : sourceFrameCount - startFrame) else {
                throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "sample frames exceed loop")
            }
            eventFrames = count
        } else if seamless {
            let fullGatedDuration = fullDuration
            guard fullGatedDuration.isFinite,
                  fullGatedDuration > 0,
                  fullGatedDuration <= sourceBeatCount * secondsPerBeat else {
                throw LoopRenderingError.invalidEvent(
                    index: eventIndex,
                    reason: "seamless event duration exceeds loop window"
                )
            }
            let renderedFrames = max(1, Int((fullGatedDuration * PreparedLoop.requiredSampleRate).rounded(.up)))
            guard renderedFrames <= sourceFrameCount else {
                throw LoopRenderingError.invalidEvent(
                    index: eventIndex,
                    reason: "seamless event duration exceeds loop frame count"
                )
            }
            eventFrames = renderedFrames
        } else {
            let gatedDuration = min(
                fullDuration,
                max(0, sourceBeatCount * secondsPerBeat - startBeat * secondsPerBeat)
            )
            eventFrames = min(
                sourceFrameCount - startFrame,
                max(1, Int((gatedDuration * PreparedLoop.requiredSampleRate).rounded(.up)))
            )
        }
        let level = Double(event.velocity) / 127 * 0.35 * event.gain
        guard event.gain.isFinite, event.gain >= 0, level.isFinite, level <= Double(Float.greatestFiniteMagnitude) else {
            throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "gain cannot be rendered as finite PCM")
        }
        let amplitude = Float(level)
        if let pan = event.pan, !pan.isFinite || !(-1...1).contains(pan) {
            throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "pan is invalid")
        }
        let leftGain = event.pan.map { Float(cos(($0 + 1) * .pi / 4)) } ?? 1
        let rightGain = event.pan.map { Float(sin(($0 + 1) * .pi / 4)) } ?? 1
        let edgeFrames = min(128, max(1, eventFrames / 2))
        return try RenderedVoice(event: event, source: source, eventIndex: eventIndex,
            startFrame: startFrame, eventFrames: eventFrames, secondsPerBeat: secondsPerBeat,
            sampleVoice: sampleVoice, amplitudeEnvelope: amplitudeEnvelope,
            amplitude: amplitude, leftGain: leftGain, rightGain: rightGain, edgeFrames: edgeFrames)
    }

    private func beatValue(_ time: MusicalTime) throws -> Double {
        let value = Double(time.numerator) / Double(time.denominator)
        guard value.isFinite else { throw LoopRenderingError.overflow }
        return value
    }
}
