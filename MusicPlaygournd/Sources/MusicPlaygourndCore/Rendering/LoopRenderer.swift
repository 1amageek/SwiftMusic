import Foundation
import SwiftMusic

public struct LoopRenderer: Sendable {
    public init() {}

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

        for (index, event) in sound.events.enumerated() {
            guard sound.sources.indices.contains(event.sourceID) else {
                throw LoopRenderingError.invalidEvent(index: index, reason: "source ID is out of range")
            }
            if let envelope = VoiceEnvelope.amplitude(event: event, source: sound.sources[event.sourceID],
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
        let beatCount = Double(bars * beatsPerBar)
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
        let frameCount = try frameCount(for: duration)

        var context = try RenderContext(
            sound: sound,
            bpm: bpm,
            beatCount: beatCount,
            frameCount: frameCount
        )
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
            let fullDuration = VoiceEnvelope.amplitude(event: event, source: source, secondsPerBeat: 60 / bpm)
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
                    max(0, beatCount - startBeat)
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

private struct StereoBuffer: Sendable {
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

private struct RenderContext: Sendable {
    let sound: CompiledSound
    let bpm: Double
    let beatCount: Double
    let frameCount: Int
    let secondsPerBeat: Double
    var nodeStates: [UInt8]
    var sourcePeakEnvelopes: [[Float]]

    init(sound: CompiledSound, bpm: Double, beatCount: Double, frameCount: Int) throws {
        self.sound = sound
        self.bpm = bpm
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
            // FIXME(INCOMPLETE_IMPLEMENTATION): procedural sample pitch traversal remains unavailable in editor evaluation until P03.3 provides rate/phase PCM tests.
            if case .sample = source.kind,
               source.tuning != nil || source.pitchEnvelope != nil || sound.events.contains(where: {
                   $0.sourceID == source.id && $0.pitchOffsetSemitones != 0
               }) {
                throw LoopRenderingError.unsupportedSourceSetting(sourceID: source.id, setting: "sample pitch traversal")
            }
            // FIXME(INCOMPLETE_IMPLEMENTATION): sampleRegion rendering is unavailable in editor evaluation; require PCM behavior tests before enabling it.
            guard source.sampleRegion == nil else {
                throw LoopRenderingError.unsupportedSourceSetting(sourceID: source.id, setting: "sampleRegion")
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
            case .synthesizer:
                break
            }
        }
    }

    mutating func renderRoots() throws -> StereoBuffer {
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
        // FIXME(INCOMPLETE_IMPLEMENTATION): effect processing is unavailable in editor evaluation; require DSP/routing behavior tests before enabling it.
        case .effect:
            throw LoopRenderingError.unsupportedRenderNode(index: nodeID, operation: "effect")
        // FIXME(INCOMPLETE_IMPLEMENTATION): send processing is unavailable in editor evaluation; require DSP/routing behavior tests before enabling it.
        case .send:
            throw LoopRenderingError.unsupportedRenderNode(index: nodeID, operation: "send")
        // FIXME(INCOMPLETE_IMPLEMENTATION): output processing is unavailable in editor evaluation; require DSP/routing behavior tests before enabling it.
        case .output:
            throw LoopRenderingError.unsupportedRenderNode(index: nodeID, operation: "output")
        }
    }

    private mutating func renderSource(_ sourceID: Int) throws -> StereoBuffer {
        let source = sound.sources[sourceID]
        var output = StereoBuffer(frameCount: frameCount)
        let sourceEvents = sound.events.enumerated().filter { $0.element.sourceID == sourceID }
        for (eventIndex, event) in sourceEvents {
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
                  seamless ? startBeat < beatCount : startBeat < beatCount + 1e-9 else {
                throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "start is outside loop")
            }
            let startFrame = max(0, min(frameCount, Int((startBeat * secondsPerBeat * PreparedLoop.requiredSampleRate).rounded(.down))))
            if seamless {
                guard startFrame < frameCount else {
                    throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "start is outside loop frames")
                }
            }
            let naturalDuration = durationBeats * secondsPerBeat
            let amplitudeEnvelope = VoiceEnvelope.amplitude(event: event, source: source,
                                                             secondsPerBeat: secondsPerBeat)
            let fullDuration = amplitudeEnvelope?.duration ?? naturalDuration * event.gate
            let eventFrames: Int
            if seamless {
                let fullGatedDuration = fullDuration
                guard fullGatedDuration.isFinite,
                      fullGatedDuration > 0,
                      fullGatedDuration <= beatCount * secondsPerBeat else {
                    throw LoopRenderingError.invalidEvent(
                        index: eventIndex,
                        reason: "seamless event duration exceeds loop window"
                    )
                }
                let renderedFrames = max(1, Int((fullGatedDuration * PreparedLoop.requiredSampleRate).rounded(.up)))
                guard renderedFrames <= frameCount else {
                    throw LoopRenderingError.invalidEvent(
                        index: eventIndex,
                        reason: "seamless event duration exceeds loop frame count"
                    )
                }
                eventFrames = renderedFrames
            } else {
                let gatedDuration = min(
                    fullDuration,
                    max(0, beatCount * secondsPerBeat - startBeat * secondsPerBeat)
                )
                eventFrames = min(
                    frameCount - startFrame,
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
            if amplitudeEnvelope == nil, source.tuning == nil, source.pitchEnvelope == nil,
               source.filter == nil, source.filterEnvelope == nil, event.pitchOffsetSemitones == 0 {
            for offset in 0..<eventFrames {
                let frame = seamless ? (startFrame + offset) % frameCount : startFrame + offset
                let time = Double(offset) / PreparedLoop.requiredSampleRate
                let edge = min(
                    1,
                    min(
                        Double(offset + 1) / Double(edgeFrames),
                        Double(eventFrames - offset) / Double(edgeFrames)
                    )
                )
                let value = sample(source.kind, pitch: event.pitch, time: time) * amplitude * Float(edge)
                output.left[frame] += value * leftGain
                output.right[frame] += value * rightGain
            }
            } else {
                let pitchContour = source.pitchEnvelope.map {
                    VoiceEnvelope($0.envelope, noteDuration: naturalDuration, gate: event.gate)
                }
                let filterContour = source.filterEnvelope.map {
                    VoiceEnvelope($0.envelope, noteDuration: naturalDuration, gate: event.gate)
                }
                let midi = Double(event.pitch?.midiNote ?? 60) + event.pitchOffsetSemitones
                let frequency = (source.tuning?.frequencyHz ?? 440)
                    * pow(2, (midi - Double(source.tuning?.referencePitch.midiNote ?? 69)) / 12)
                let pitchDepth = source.pitchEnvelope?.depth.value ?? 0
                let filterDepth = source.filterEnvelope?.depth.value ?? 0
                if case .synthesizer = source.kind {
                    try validateFrequency(frequency, depth: pitchDepth, eventIndex: eventIndex)
                }
                var filter = source.filter.map(VoiceFilter.init)
                if filter != nil {
                    guard let cutoff = event.cutoffHz else {
                        throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "source filter requires event cutoff")
                    }
                    try validateFrequency(cutoff, depth: filterDepth, eventIndex: eventIndex)
                } else if event.cutoffHz != nil {
                    throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "cutoff requires a source filter")
                }
                var phase = 0.0
                for offset in 0..<eventFrames {
                    let frame = seamless ? (startFrame + offset) % frameCount : startFrame + offset
                    let time = Double(offset) / PreparedLoop.requiredSampleRate
                    var raw: Double
                    switch source.kind {
                    case .synthesizer(let waveform):
                        let currentFrequency = frequency * pow(2, pitchDepth * (pitchContour?.value(at: time) ?? 0) / 12)
                        let currentPhase = pitchContour == nil
                            ? (time * frequency).truncatingRemainder(dividingBy: 1) : phase
                        raw = Double(oscillator(waveform, phase: currentPhase, time: time))
                        phase = (phase + currentFrequency / PreparedLoop.requiredSampleRate)
                            .truncatingRemainder(dividingBy: 1)
                    case .sample:
                        raw = Double(sample(source.kind, pitch: event.pitch, time: time))
                    }
                    if filter != nil, let cutoff = event.cutoffHz {
                        let frequency = cutoff * pow(2, filterDepth * (filterContour?.value(at: time) ?? 0) / 12)
                        if let filtered = try filter?.process(raw, cutoff: frequency, eventIndex: eventIndex) {
                            raw = filtered
                        }
                    }
                    let contour: Double
                    if let amplitudeEnvelope {
                        contour = amplitudeEnvelope.value(at: time)
                    } else {
                        contour = min(1, min(Double(offset + 1) / Double(edgeFrames),
                                             Double(eventFrames - offset) / Double(edgeFrames)))
                    }
                    let value = raw * Double(amplitude) * contour
                    guard value.isFinite, abs(value) <= Double(Float.greatestFiniteMagnitude) else {
                        throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "non-finite source PCM")
                    }
                    output.left[frame] += Float(value) * leftGain
                    output.right[frame] += Float(value) * rightGain
                }
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

    private func sample(_ kind: SourceKind, pitch: Pitch?, time: Double) -> Float {
        switch kind {
        case .synthesizer(let waveform):
            let midi = Double(pitch?.midiNote ?? 60)
            let frequency = 440 * pow(2, (midi - 69) / 12)
            let phase = (time * frequency).truncatingRemainder(dividingBy: 1)
            return oscillator(waveform, phase: phase, time: time)
        case .sample(let name):
            let decay: Double
            switch name {
            case "kick":
                let frequency = 140 * exp(-18 * time) + 45
                return Float(sin(2 * .pi * frequency * time) * exp(-11 * time))
            case "snare":
                decay = exp(-24 * time)
                return Float((Double(deterministicNoise(time: time)) * 0.9 + sin(2 * .pi * 180 * time) * 0.1) * decay)
            case "closedHat":
                return Float(Double(deterministicNoise(time: time)) * exp(-45 * time))
            default:
                return 0
            }
        }
    }

    private func validateFrequency(_ frequency: Double, depth: Double, eventIndex: Int) throws {
        let endpoint = frequency * pow(2, depth / 12)
        let nyquist = PreparedLoop.requiredSampleRate / 2
        guard frequency.isFinite, frequency > 0, frequency < nyquist,
              endpoint.isFinite, endpoint > 0, endpoint < nyquist else {
            throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "frequency must be positive and below Nyquist")
        }
    }

    private func oscillator(_ waveform: Waveform, phase: Double, time: Double) -> Float {
        switch waveform {
        case .sine: Float(sin(2 * .pi * phase))
        case .square: phase < 0.5 ? 1 : -1
        case .saw: Float(2 * phase - 1)
        case .triangle: Float(1 - 4 * abs((phase - 0.5).rounded() - (phase - 0.5)))
        case .noise: deterministicNoise(time: time)
        }
    }

    private func deterministicNoise(time: Double) -> Float {
        let frame = UInt64(max(0, Int(time * PreparedLoop.requiredSampleRate)))
        var value = frame &* 2_862_933_555_777_941_757 &+ 1
        value ^= value >> 30
        value &*= 0xbf58476d1ce4e5b9
        value ^= value >> 27
        value &*= 0x94d049bb133111eb
        value ^= value >> 31
        return Float(Double(Int64(bitPattern: value)) / Double(Int64.max))
    }

    private func beatValue(_ time: MusicalTime) throws -> Double {
        let value = Double(time.numerator) / Double(time.denominator)
        guard value.isFinite else { throw LoopRenderingError.overflow }
        return value
    }
}
