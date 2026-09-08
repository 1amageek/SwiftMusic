import Foundation
import SwiftMusic

public struct LoopRenderer: Sendable {
    private let sampleLoader: any SampleLoading

    public init(sampleLoader: any SampleLoading = AVAudioFileSampleLoader()) {
        self.sampleLoader = sampleLoader
    }

    internal func validateBasicInputs(
        _ sound: CompiledSound,
        bpm: Double,
        beatsPerBar: Int
    ) throws {
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
        let extent = try beatValue(sound.extent)
        guard extent.isFinite, extent >= 0 else { throw LoopRenderingError.invalidSound("non-finite extent") }
        guard extent <= PreparedLoop.maximumBeatCount else { throw LoopRenderingError.extentTooLong(extent) }
        try AutomationEvaluator.validate(sound, bpm: bpm, windowBeats: max(extent, Double(beatsPerBar)))
    }

    public func render(
        _ sound: CompiledSound,
        bpm: Double,
        beatsPerBar: Int
    ) throws -> PreparedLoop {
        try validateBasicInputs(sound, bpm: bpm, beatsPerBar: beatsPerBar)
        let preparedSamples = try SamplePreparation(sound: sound, loader: sampleLoader, secondsPerBeat: 60 / bpm)
        let preparedOscillators = try OscillatorPreparation.prepare(sound)
        return try renderPrepared(sound, bpm: bpm, beatsPerBar: beatsPerBar,
                                  preparedSamples: preparedSamples, preparedOscillators: preparedOscillators)
    }

    internal func renderPrepared(
        _ sound: CompiledSound,
        bpm: Double,
        beatsPerBar: Int,
        preparedSamples: SamplePreparation,
        preparedOscillators: [Int: OscillatorPreparation],
        overlay: RenderControlOverlay? = nil
    ) throws -> PreparedLoop {
        try renderPreparedResult(
            sound,
            bpm: bpm,
            beatsPerBar: beatsPerBar,
            preparedSamples: preparedSamples,
            preparedOscillators: preparedOscillators,
            overlay: overlay,
            captureTrackStems: false
        ).loop
    }

    internal func renderPreparedAndStems(
        _ sound: CompiledSound,
        bpm: Double,
        beatsPerBar: Int,
        preparedSamples: SamplePreparation,
        preparedOscillators: [Int: OscillatorPreparation],
        overlay: RenderControlOverlay? = nil
    ) throws -> (loop: PreparedLoop, stems: [PreparedStem]) {
        try renderPreparedResult(
            sound,
            bpm: bpm,
            beatsPerBar: beatsPerBar,
            preparedSamples: preparedSamples,
            preparedOscillators: preparedOscillators,
            overlay: overlay,
            captureTrackStems: true
        )
    }

    private func renderPreparedResult(
        _ sound: CompiledSound,
        bpm: Double,
        beatsPerBar: Int,
        preparedSamples: SamplePreparation,
        preparedOscillators: [Int: OscillatorPreparation],
        overlay: RenderControlOverlay?,
        captureTrackStems: Bool
    ) throws -> (loop: PreparedLoop, stems: [PreparedStem]) {
        try validateBasicInputs(sound, bpm: bpm, beatsPerBar: beatsPerBar)
        var extent = try beatValue(sound.extent)
        let automationSecondsPerBeat = sound.playbackMode == .seamlessLoop
            ? ceil(extent * 60 / bpm * PreparedLoop.requiredSampleRate) / PreparedLoop.requiredSampleRate / extent
            : 60 / bpm

        var sampleFrames: [Int: Int] = [:]
        let maximumSeconds = min(PreparedLoop.maximumDurationSeconds, PreparedLoop.maximumBeatCount * 60 / bpm)
        for (index, voice) in preparedSamples.voices {
            let event = sound.events[index]
            let source = sound.sources[event.sourceID]
            let available = sound.playbackMode == .seamlessLoop ? extent * 60 / bpm
                : max(0, maximumSeconds - (try beatValue(event.start)) * 60 / bpm)
            let frames = try voice.frames(event: event, source: source, secondsPerBeat: 60 / bpm,
                                          limit: Int((available * PreparedLoop.requiredSampleRate).rounded(.down)),
                                          automationSecondsPerBeat: automationSecondsPerBeat,
                                          pitchAutomationOverride: overlay?.sourcePitch[source.id])
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
            preparedOscillators: preparedOscillators,
            sampleFrames: sampleFrames,
            overlay: overlay,
            captureTrackStems: captureTrackStems
        )
        let sourceBeatCount = beatCount
        try context.prepareEffects(beatsPerBar: beatsPerBar)
        if context.beatCount != beatCount {
            try AutomationEvaluator.validate(sound, bpm: bpm, windowBeats: context.beatCount)
        }
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
                wrapsLoopBoundary: wrapsLoopBoundary,
                midiProjection: try MIDIPitchProjection.resolve(event: event, source: source,
                    frames: sampleFrames[index] ?? min(
                        sound.playbackMode == .seamlessLoop ? context.sourceFrameCount : context.sourceFrameCount
                            - Int((startBeat * 60 / bpm * PreparedLoop.requiredSampleRate).rounded(.down)),
                        Int((audibleDuration * 60 / bpm * PreparedLoop.requiredSampleRate).rounded(.up))),
                    secondsPerBeat: 60 / bpm, automationSecondsPerBeat: automationSecondsPerBeat,
                    override: overlay?.sourcePitch[source.id])
            )
        }
        let rows = sound.sources.enumerated().map { index, source in
            LoopRow(
                sourceID: source.id,
                label: self.label(for: source.id, in: sound),
                anchor: source.patternAnchor,
                peaks: context.sourcePeakEnvelopes[index],
                patternText: source.patternText,
                trackID: sound.events.first(where: { $0.sourceID == source.id })?.trackID
            )
        }

        let prepared = PreparedLoop(
            sampleRate: PreparedLoop.requiredSampleRate,
            bpm: bpm,
            beatsPerBar: beatsPerBar,
            beatCount: beatCount,
            samples: samples,
            events: events,
            rows: rows,
            meters: context.meters
        )
        do {
            try prepared.validate()
        } catch let error as PreparedLoopValidationError {
            throw LoopRenderingError.invalidPreparedLoop(error)
        }
        var stems: [PreparedStem] = []
        if captureTrackStems {
            guard sound.tracks.count <= StemExporter.maximumStemCount else {
                throw LoopRenderingError.invalidSound("track stem count exceeds 32")
            }
            stems.reserveCapacity(sound.tracks.count)
            for track in sound.tracks {
                guard track.renderNodeID != nil else { continue }
                guard let buffer = context.capturedStems[track.id] else {
                    throw LoopRenderingError.invalidSound("Track stem boundary was not rendered.")
                }
                stems.append(try PreparedStem(
                    trackID: track.id,
                    label: track.name,
                    sampleRate: PreparedLoop.requiredSampleRate,
                    bpm: bpm,
                    beatsPerBar: beatsPerBar,
                    beatCount: beatCount,
                    samples: buffer.interleaved
                ))
            }
        }
        return (prepared, stems)
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
            case .bandLimitedSaw: "band-limited saw"
            case .pulse: "pulse"
            case .frequencyModulation: "FM"
            case .coloredNoise: "colored noise"
            case .wavetable: "wavetable"
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
        for index in left.indices {
            left[index] = 0
            right[index] = 0
        }
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
    var audibleTracks: [Bool] = []
    var admittedSources: [Bool] = []
    let secondsPerBeat: Double
    let automationSecondsPerBeat: Double
    var nodeConsumers: [Int]
    var nodeBuffers: [StereoBuffer?]
    var neededNodes: [Bool]
    var sourcePeakEnvelopes: [[Float]]
    let preparedSamples: SamplePreparation
    let preparedOscillators: [Int: OscillatorPreparation]
    let sampleFrames: [Int: Int]
    let overlay: RenderControlOverlay?
    let captureTrackStems: Bool
    var meters: [PreparedMeterEnvelope] = []
    var capturedStems: [Int: StereoBuffer] = [:]
    var scheduledSources: [StereoBuffer]?

    init(sound: CompiledSound, bpm: Double, beatCount: Double, frameCount: Int,
         preparedSamples: SamplePreparation, preparedOscillators: [Int: OscillatorPreparation], sampleFrames: [Int: Int],
         overlay: RenderControlOverlay? = nil, captureTrackStems: Bool = false) throws {
        self.preparedSamples = preparedSamples
        self.preparedOscillators = preparedOscillators
        self.sampleFrames = sampleFrames
        self.overlay = overlay
        self.captureTrackStems = captureTrackStems
        self.sound = sound
        self.bpm = bpm
        self.sourceBeatCount = beatCount
        self.sourceFrameCount = frameCount
        self.beatCount = beatCount
        self.frameCount = frameCount
        self.secondsPerBeat = 60 / bpm
        self.automationSecondsPerBeat = sound.playbackMode == .seamlessLoop
            ? Double(frameCount) / PreparedLoop.requiredSampleRate / beatCount : 60 / bpm
        self.nodeConsumers = Array(repeating: 0, count: sound.renderNodes.count)
        self.nodeBuffers = Array(repeating: nil, count: sound.renderNodes.count)
        self.neededNodes = Array(repeating: false, count: sound.renderNodes.count)
        self.sourcePeakEnvelopes = Array(
            repeating: [Float](repeating: 0, count: 1),
            count: sound.sources.count
        )

        try prepareTracks()
        try prepareRouting()

        for event in sound.events {
            let source = sound.sources[event.sourceID]
            guard (event.cutoffHz != nil) == (source.filter != nil) else {
                throw LoopRenderingError.invalidSound("source filter and event cutoff must be paired")
            }
        }
        for source in sound.sources {
            let noise: Bool
            switch source.kind {
            case .synthesizer(.noise), .synthesizer(.coloredNoise): noise = true
            default: noise = false
            }
            if noise,
               source.portamento != nil || source.tuning != nil || source.pitchEnvelope != nil || source.pitchAutomation != nil || sound.events.contains(where: {
                   $0.sourceID == source.id && $0.pitchOffsetSemitones != 0
               }) {
                throw LoopRenderingError.unsupportedSourceSetting(sourceID: source.id, setting: "white noise has no pitched oscillator")
            }
            if source.filterEnvelope != nil, source.filter == nil {
                throw LoopRenderingError.unsupportedSourceSetting(sourceID: source.id, setting: "filterEnvelope requires a source filter")
            }
            // Procedural samples have no decoded asset or root pitch; rooted file/bank sources support pitch traversal.
            if case .sample = source.kind,
               source.portamento != nil || source.tuning != nil || source.pitchEnvelope != nil || source.pitchAutomation != nil || sound.events.contains(where: {
                   $0.sourceID == source.id && $0.pitchOffsetSemitones != 0
               }) {
                throw LoopRenderingError.unsupportedSourceSetting(sourceID: source.id, setting: "sample pitch traversal")
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

    private mutating func prepareTracks() throws {
        let hasSolo = sound.tracks.contains { $0.isSoloed }
        audibleTracks = [Bool](repeating: !hasSolo, count: sound.tracks.count)
        admittedSources = [Bool](repeating: true, count: sound.sources.count)
        for (index, track) in sound.tracks.enumerated() {
            let level = overlay?.trackLevel[index] ?? track.level
            let pan = overlay.map { $0.effectiveTrackPan(index, baseline: track.pan) } ?? track.pan
            guard track.id == index, level.isFinite, level >= 0,
                  pan.map({ $0.isFinite && (-1...1).contains($0) }) ?? true else {
                throw LoopRenderingError.invalidSound("invalid track metadata")
            }
            if let parent = track.parentID, parent < 0 || parent >= index {
                throw LoopRenderingError.invalidSound("track ancestry must be dependency ordered")
            }
            if let node = track.renderNodeID {
                guard sound.renderNodes.indices.contains(node),
                      case .track(_, let id) = sound.renderNodes[node], id == index else {
                    throw LoopRenderingError.invalidSound("track metadata and node disagree")
                }
            }
        }
        // Compiler track IDs are nonnegative; -2 is unseen and -1 is untracked.
        var sourceOwners = [Int](repeating: -2, count: sound.sources.count)
        for event in sound.events {
            let owner = event.trackID ?? -1
            guard event.trackID == nil || sound.tracks.indices.contains(owner) else {
                throw LoopRenderingError.invalidSound("event track ID is invalid")
            }
            guard sourceOwners[event.sourceID] == -2 || sourceOwners[event.sourceID] == owner else {
                throw LoopRenderingError.invalidSound("source has conflicting track owners")
            }
            sourceOwners[event.sourceID] = owner
        }
        if hasSolo {
            for track in sound.tracks {
                var ancestor: Int? = track.id
                while let id = ancestor {
                    if sound.tracks[id].isSoloed { audibleTracks[track.id] = true; break }
                    ancestor = sound.tracks[id].parentID
                }
            }
            // Source admission excludes ancestors that merely carry a soloed child.
            for source in sourceOwners.indices {
                let owner = sourceOwners[source]
                admittedSources[source] = owner >= 0 && audibleTracks[owner]
            }
            for track in sound.tracks where track.isSoloed {
                var ancestor: Int? = track.parentID
                while let id = ancestor {
                    audibleTracks[id] = true
                    ancestor = sound.tracks[id].parentID
                }
            }
        }
        for (node, value) in sound.renderNodes.enumerated() {
            if case .track(let input, let id) = value {
                guard sound.tracks.indices.contains(id), sound.tracks[id].renderNodeID == node,
                      input >= 0, input < node else {
                    throw LoopRenderingError.invalidSound("invalid track node")
                }
            }
        }
    }

    private func inputs(of node: CompiledRenderNode) -> [Int] {
        switch node {
        case .source: return []
        case .mix(let inputs), .busReturn(_, let inputs): return inputs
        case .eventDuck(let input, _): return [input]
        case .sidechainEffect(let input, let sidechain, _): return [input, sidechain]
        case .effect(let input, _), .gain(let input, _), .pan(let input, _),
             .gainAutomation(let input, _), .panAutomation(let input, _),
             .track(let input, _), .mute(let input), .send(let input, _, _),
             .trackSend(let input, _, _, _, _), .output(let input, _): return [input]
        }
    }

    private mutating func prepareRouting() throws {
        var returns: [String: [Int]] = [:]
        var sends: [String: [Int]] = [:]
        var sourceNodes: Set<Int> = []
        for (index, node) in sound.renderNodes.enumerated() {
            for input in inputs(of: node) {
                guard input >= 0, input < index else {
                    throw LoopRenderingError.invalidSound("render nodes must be dependency ordered")
                }
            }
            switch node {
            case .eventDuck(let input, let rules):
                guard case .busReturn(let bus, _) = sound.renderNodes[input],
                      !rules.isEmpty, Set(rules).count == rules.count,
                      rules.allSatisfy({ sound.eventDucks.indices.contains($0) && sound.eventDucks[$0].targetBus == bus }) else {
                    throw LoopRenderingError.invalidSound("invalid duck return boundary")
                }
            case .sidechainEffect(_, let sidechain, let compressor):
                let boundary: Int
                if case .eventDuck(let input, _) = sound.renderNodes[sidechain] { boundary = input }
                else { boundary = sidechain }
                guard case .busReturn(let bus, _) = sound.renderNodes[boundary], compressor.sidechainBus == bus else {
                    throw LoopRenderingError.invalidSound("invalid sidechain return boundary")
                }
            case .source(let id):
                guard sound.sources.indices.contains(id), sourceNodes.insert(id).inserted else {
                    throw LoopRenderingError.invalidSound("invalid or duplicate source node")
                }
            case .send(_, let bus, let level), .trackSend(_, let bus, let level, _, _):
                guard !bus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      level.isFinite, level >= 0 else {
                    throw LoopRenderingError.invalidSound("invalid bus send")
                }
                sends[bus, default: []].append(index)
                if case .trackSend(_, _, _, let track, _) = node,
                   !sound.tracks.indices.contains(track) {
                    throw LoopRenderingError.invalidSound("send track ID is out of range")
                }
            case .busReturn(let bus, let inputs):
                guard !bus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      returns[bus] == nil, !inputs.isEmpty else {
                    throw LoopRenderingError.invalidSound("invalid or duplicate bus return")
                }
                returns[bus] = inputs
            case .output(_, let name):
                guard name == "main" else {
                    throw LoopRenderingError.unsupportedRenderNode(index: index, operation: "external output \(name)")
                }
            default: break
            }
        }
        guard returns.count <= 32 else { throw LoopRenderingError.invalidSound("maximum 32 buses exceeded") }
        for (bus, contributions) in sends {
            guard let inputs = returns[bus] else {
                throw LoopRenderingError.unsupportedRenderNode(index: contributions[0], operation: "unresolved send bus \(bus)")
            }
            guard inputs.count == contributions.count, Set(inputs) == Set(contributions) else {
                throw LoopRenderingError.invalidSound("bus contribution identities disagree")
            }
        }
        guard returns.keys.allSatisfy({ sends[$0] != nil }) else {
            throw LoopRenderingError.invalidSound("bus return has no sends")
        }
        let dynamicsCount = sound.renderNodes.filter { node in
            switch node {
            case .eventDuck, .sidechainEffect,
                 .effect(_, .compressor), .effect(_, .sidechainCompressor),
                 .effect(_, .noiseGate), .effect(_, .limiter): return true
            default: return false
            }
        }.count
        let modulationCount = sound.renderNodes.reduce(into: 0) { count, node in
            switch node {
            case .effect(_, .chorus), .effect(_, .flanger), .effect(_, .phaser), .effect(_, .stereoWidth): count += 1
            default: break
            }
        }
        guard modulationCount <= 32 else {
            throw LoopRenderingError.invalidSound("modulation node count exceeds 32")
        }
        guard dynamicsCount <= 32, sound.eventDucks.count <= 1_024 else {
            throw LoopRenderingError.invalidSound("dynamics node or duck rule limit exceeded")
        }
        var usedRules = Set<Int>()
        for node in sound.renderNodes {
            if case .eventDuck(_, let rules) = node {
                for rule in rules where !usedRules.insert(rule).inserted {
                    throw LoopRenderingError.invalidSound("duplicate duck rule identity")
                }
            }
        }
        guard usedRules.count == sound.eventDucks.count else {
            throw LoopRenderingError.invalidSound("unresolved duck rules")
        }
        var pending = sound.rootNodeIDs
        while let node = pending.popLast() {
            guard sound.renderNodes.indices.contains(node) else {
                throw LoopRenderingError.invalidSound("root node ID is out of range")
            }
            if neededNodes[node] { continue }
            neededNodes[node] = true
            pending.append(contentsOf: inputs(of: sound.renderNodes[node]))
        }
        for index in sound.renderNodes.indices where neededNodes[index] {
            try Task.checkCancellation()
            for input in inputs(of: sound.renderNodes[index]) { nodeConsumers[input] += 1 }
        }
        for root in sound.rootNodeIDs { nodeConsumers[root] += 1 }

        // A final input can transfer its buffer to the output; shared inputs
        // remain retained while COW supplies a separate mutable output.
        var remaining = nodeConsumers
        let schedulesVoices = sound.sources.contains { $0.voicePolicy != nil || $0.chokeGroup != nil }
        var live = schedulesVoices ? sound.sources.count : 0
        var peak = live
        for index in sound.renderNodes.indices where neededNodes[index] {
            let inputs = inputs(of: sound.renderNodes[index])
            let reusesFirst = inputs.first.map { remaining[$0] == 1 } ?? false
            let preallocatedSource: Bool
            if case .source = sound.renderNodes[index] { preallocatedSource = schedulesVoices }
            else { preallocatedSource = false }
            let effectWorkspace: Int
            switch sound.renderNodes[index] {
            case .effect(_, .chorus(_, _, let wet)): effectWorkspace = wet == 0 ? 0 : 1
            case .effect(_, .flanger(_, _, _, _, let wet)): effectWorkspace = wet == 0 ? 0 : 2
            case .eventDuck: effectWorkspace = 1
            case .effect(_, .delay(_, _, let wet)), .effect(_, .reverb(_, let wet)):
                effectWorkspace = wet == 0 ? 0 : 1
            default: effectWorkspace = 0
            }
            peak = max(peak, live + (reusesFirst || preallocatedSource ? 0 : 1) + effectWorkspace)
            for input in inputs {
                remaining[input] -= 1
                if remaining[input] == 0 { live -= 1 }
            }
            if !preallocatedSource { live += 1 }
        }
        if let first = sound.rootNodeIDs.first {
            peak = max(peak, live + (remaining[first] == 1 ? 0 : 1))
        }
        guard peak <= 32 else {
            throw LoopRenderingError.invalidSound("render graph exceeds 32 live stereo buffers")
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
            case .gain(let input, _), .pan(let input, _), .mute(let input), .track(let input, _),
                 .gainAutomation(let input, _), .panAutomation(let input, _),
                 .send(let input, _, _), .trackSend(let input, _, _, _, _), .output(let input, _):
                value = try horizon(input)
            case .busReturn(_, let inputs): value = try inputs.reduce(0) { max($0, try horizon($1)) }
            case .eventDuck(let input, _), .sidechainEffect(let input, _, _): value = try horizon(input)
            case .effect(let input, let effect):
                let tail = try EffectProcessor.tailFrames(effect, bpm: bpm, node: index)
                value = try horizon(input) + tail
                switch effect {
                case .reverb(_, let wet), .delay(_, _, let wet):
                    if wet != 0 { maximumImpulse = max(maximumImpulse, tail + 1) }
                default: break
                }
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

    private func validateGrainBudget() throws {
        var slots = 0
        var launches = 0
        for (index, event) in sound.events.enumerated() {
            guard let configuration = sound.sources[event.sourceID].granularPlayback else { continue }
            guard let frames = sampleFrames[index] else {
                throw LoopRenderingError.invalidSound("granular event requires decoded PCM")
            }
            let dimensions = try GranularSampleVoice.dimensions(configuration, eventFrames: frames)
            // Bound retained template rings as well as active grains, before their allocation.
            slots += dimensions.slots
            launches += dimensions.launches * (sound.playbackMode == .seamlessLoop ? 2 : 1)
            guard slots <= 4096, launches <= 1_048_576 else {
                throw LoopRenderingError.invalidSound("granular render exceeds grain budget")
            }
        }
    }

    mutating func renderRoots() throws -> StereoBuffer {
        try validateGrainBudget()
        if sound.sources.contains(where: { $0.voicePolicy != nil || $0.chokeGroup != nil || $0.granularPlayback != nil || preparedOscillators[$0.id] != nil }) {
            scheduledSources = try VoiceScheduler.render(
                templates: sound.events.indices.compactMap { index in
                    let voice = try makeVoice(index)
                    return admittedSources[voice.source.id] ? voice : nil
                },
                sourceCount: sound.sources.count, frameCount: frameCount,
                seamless: sound.playbackMode == .seamlessLoop)
        }
        var meterBoundaries: [Int: PreparedMeterEnvelope.Target] = [:]
        for (index, node) in sound.renderNodes.enumerated() {
            switch node {
            case .track(_, let id): meterBoundaries[index] = .track(id)
            case .busReturn(let name, _): meterBoundaries[index] = .bus(name)
            case .eventDuck(let input, _):
                if let target = meterBoundaries.removeValue(forKey: input) { meterBoundaries[index] = target }
            default: break
            }
        }
        for index in sound.renderNodes.indices where neededNodes[index] {
            let rendered = try renderNode(index)
            if let target = meterBoundaries[index] {
                let label: String
                switch target {
                case .track(let id): label = sound.tracks[id].name
                case .bus(let name): label = name
                }
                meters.append(PreparedMeterEnvelope(target: target, label: label, peaks: peakEnvelope(for: rendered)))
            }
            nodeBuffers[index] = rendered
        }
        guard let first = sound.rootNodeIDs.first else { return StereoBuffer(frameCount: frameCount) }
        var output = try takeNode(first)
        for root in sound.rootNodeIDs.dropFirst() {
            try add(try takeNode(root), to: &output)
        }
        guard output.left.allSatisfy({ $0.isFinite }), output.right.allSatisfy({ $0.isFinite }) else {
            throw LoopRenderingError.invalidSound("non-finite graph output")
        }
        return output
    }

    private mutating func takeNode(_ id: Int) throws -> StereoBuffer {
        guard nodeBuffers.indices.contains(id), nodeConsumers[id] > 0, let buffer = nodeBuffers[id] else {
            throw LoopRenderingError.invalidSound("render node consumed outside its lifetime")
        }
        nodeConsumers[id] -= 1
        if nodeConsumers[id] == 0 { nodeBuffers[id] = nil }
        return buffer
    }

    private mutating func renderNode(_ nodeID: Int) throws -> StereoBuffer {
        switch sound.renderNodes[nodeID] {
        case .source(let sourceID):
            guard sourceID >= 0, sourceID < sound.sources.count else {
                throw LoopRenderingError.invalidSound("source node ID is out of range")
            }
            return try renderSource(sourceID)
        case .mix(let inputs):
            guard let first = inputs.first else { return StereoBuffer(frameCount: frameCount) }
            var output = try takeNode(first)
            for input in inputs.dropFirst() { try add(try takeNode(input), to: &output) }
            return output
        case .gain(let input, let value):
            let effectiveValue = overlay?.nodeGain[nodeID] ?? value
            guard effectiveValue.isFinite, effectiveValue >= 0 else {
                throw LoopRenderingError.invalidSound("gain is invalid")
            }
            var output = try takeNode(input)
            if overlay?.nodeGain[nodeID] != nil { try scale(&output, by: effectiveValue) }
            else { output.multiply(by: Float(value)) }
            return output
        case .pan(let input, let value):
            let effectiveValue = overlay?.nodePan[nodeID] ?? value
            guard effectiveValue.isFinite, (-1...1).contains(effectiveValue) else {
                throw LoopRenderingError.invalidSound("pan is invalid")
            }
            var output = try takeNode(input)
            output.applyPan(effectiveValue)
            return output
        case .gainAutomation(let input, let automation):
            var output = try takeNode(input)
            if let value = overlay?.nodeGain[nodeID] {
                guard value.isFinite, value >= 0 else {
                    throw LoopRenderingError.invalidSound("gain is invalid")
                }
                try scale(&output, by: value)
                return output
            }
            for frame in output.left.indices {
                let gain = try AutomationEvaluator.mapped(automation.signal,
                    from: automation.from, to: automation.to, frame: frame, secondsPerBeat: automationSecondsPerBeat)
                let left = Double(output.left[frame]) * gain
                let right = Double(output.right[frame]) * gain
                guard left.isFinite, right.isFinite,
                      abs(left) <= Double(Float.greatestFiniteMagnitude),
                      abs(right) <= Double(Float.greatestFiniteMagnitude) else {
                    throw LoopRenderingError.invalidSound("automated gain exceeds finite PCM range")
                }
                output.left[frame] = Float(left)
                output.right[frame] = Float(right)
            }
            return output
        case .panAutomation(let input, let automation):
            var output = try takeNode(input)
            if let value = overlay?.nodePan[nodeID] {
                guard value.isFinite, (-1...1).contains(value) else {
                    throw LoopRenderingError.invalidSound("pan is invalid")
                }
                output.applyPan(value)
                return output
            }
            for frame in output.left.indices {
                let pan = try AutomationEvaluator.mapped(automation.signal,
                    from: automation.from, to: automation.to, frame: frame, secondsPerBeat: automationSecondsPerBeat)
                let angle = (pan + 1) * .pi / 4
                let left = Double(output.left[frame]) * cos(angle)
                let right = Double(output.right[frame]) * sin(angle)
                guard left.isFinite, right.isFinite,
                      abs(left) <= Double(Float.greatestFiniteMagnitude),
                      abs(right) <= Double(Float.greatestFiniteMagnitude) else {
                    throw LoopRenderingError.invalidSound("automated pan exceeds finite PCM range")
                }
                output.left[frame] = Float(left)
                output.right[frame] = Float(right)
            }
            return output
        case .mute(let input):
            var output = try takeNode(input)
            output.mute()
            return output
        case .track(let input, let id):
            var output = try takeNode(input)
            let track = sound.tracks[id]
            let level = overlay?.trackLevel[id] ?? track.level
            let pan = overlay.map { $0.effectiveTrackPan(id, baseline: track.pan) } ?? track.pan
            guard level.isFinite, level >= 0,
                  pan.map({ $0.isFinite && (-1...1).contains($0) }) ?? true else {
                throw LoopRenderingError.invalidSound("invalid track metadata")
            }
            if level != 1 {
                for index in output.left.indices {
                    let left = Double(output.left[index]) * level
                    let right = Double(output.right[index]) * level
                    guard left.isFinite, right.isFinite,
                          abs(left) <= Double(Float.greatestFiniteMagnitude),
                          abs(right) <= Double(Float.greatestFiniteMagnitude) else {
                        throw LoopRenderingError.invalidSound("track level exceeds finite PCM range")
                    }
                    output.left[index] = Float(left)
                    output.right[index] = Float(right)
                }
            }
            if let pan { output.applyPan(pan) }
            if (overlay?.trackMute[id] ?? track.isMuted) || !audibleTracks[id] { output.mute() }
            if captureTrackStems {
                guard capturedStems[id] == nil else {
                    throw LoopRenderingError.invalidSound("Track stem boundary was captured twice.")
                }
                capturedStems[id] = output
            }
            return output
        case .effect(let input, let effect):
            var output = try takeNode(input)
            try EffectProcessor.apply(effect, to: &output, inputHorizon: nodeHorizons[input],
                                      bpm: bpm, seamless: sound.playbackMode == .seamlessLoop,
                                      node: nodeID, convolver: convolver)
            return output
        case .eventDuck(let input, let rules):
            var output = try takeNode(input)
            try DynamicsProcessor.duck(&output, rules: rules, sound: sound,
                                       secondsPerBeat: secondsPerBeat, seamless: sound.playbackMode == .seamlessLoop)
            return output
        case .sidechainEffect(let input, let sidechain, let compressor):
            var output = try takeNode(input)
            let detector = try takeNode(sidechain)
            try DynamicsProcessor(.sidechainCompressor(compressor)).process(&output, sidechain: detector,
                seamless: sound.playbackMode == .seamlessLoop)
            return output
        case .send(let input, _, _), .trackSend(let input, _, _, _, _), .output(let input, _):
            return try takeNode(input)
        case .busReturn(_, let inputs):
            guard let first = inputs.first else { throw LoopRenderingError.invalidSound("empty bus return") }
            var output = try takeNode(first)
            try scale(&output, by: sendLevel(first))
            for input in inputs.dropFirst() {
                try add(try takeNode(input), to: &output, level: sendLevel(input))
            }
            return output
        }
    }

    private func sendLevel(_ node: Int) -> Double {
        switch sound.renderNodes[node] {
        case .send(_, _, let level): return level
        case .trackSend(_, _, let level, let track, _):
            guard audibleTracks[track] else { return 0 }
            var owner: Int? = track
            while let id = owner {
                if overlay?.trackMute[id] ?? sound.tracks[id].isMuted { return 0 }
                owner = sound.tracks[id].parentID
            }
            return level
        default: preconditionFailure("Routing validation admits only send contributions")
        }
    }

    private func scale(_ output: inout StereoBuffer, by level: Double) throws {
        for frame in output.left.indices {
            let left = Double(output.left[frame]) * level
            let right = Double(output.right[frame]) * level
            guard left.isFinite, right.isFinite,
                  abs(left) <= Double(Float.greatestFiniteMagnitude), abs(right) <= Double(Float.greatestFiniteMagnitude) else {
                throw LoopRenderingError.invalidSound("send level exceeds finite PCM range")
            }
            output.left[frame] = Float(left)
            output.right[frame] = Float(right)
        }
    }

    private func add(_ input: StereoBuffer, to output: inout StereoBuffer, level: Double = 1) throws {
        for frame in output.left.indices {
            let left = Double(output.left[frame]) + Double(input.left[frame]) * level
            let right = Double(output.right[frame]) + Double(input.right[frame]) * level
            guard left.isFinite, right.isFinite,
                  abs(left) <= Double(Float.greatestFiniteMagnitude), abs(right) <= Double(Float.greatestFiniteMagnitude) else {
                throw LoopRenderingError.invalidSound("bus or main mix exceeds finite PCM range")
            }
            output.left[frame] = Float(left)
            output.right[frame] = Float(right)
        }
    }

    private mutating func renderSource(_ sourceID: Int) throws -> StereoBuffer {
        if scheduledSources != nil {
            var output = scheduledSources![sourceID]
            // Transfer the scheduler's ownership so a final consumer can reuse
            // this buffer without a hidden retained copy outside the graph plan.
            scheduledSources![sourceID] = StereoBuffer(frameCount: 0)
            try applySourceOverlay(to: &output, sourceID: sourceID)
            sourcePeakEnvelopes[sourceID] = peakEnvelope(for: output)
            return output
        }
        if !admittedSources[sourceID] { return StereoBuffer(frameCount: frameCount) }
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
        try applySourceOverlay(to: &output, sourceID: sourceID)
        sourcePeakEnvelopes[sourceID] = peakEnvelope(for: output)
        return output
    }

    private func applySourceOverlay(to output: inout StereoBuffer, sourceID: Int) throws {
        if let gain = overlay?.sourceGain[sourceID] {
            guard gain.isFinite, gain >= 0 else {
                throw LoopRenderingError.invalidSound("source gain is invalid")
            }
            try scale(&output, by: gain)
        }
        if let pan = overlay?.sourcePan[sourceID] {
            guard pan.isFinite, (-1...1).contains(pan) else {
                throw LoopRenderingError.invalidSound("source pan is invalid")
            }
            output.applyPan(pan)
        }
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
            oscillator: preparedOscillators[source.id],
            amplitude: amplitude, leftGain: leftGain, rightGain: rightGain, edgeFrames: edgeFrames,
            automationSecondsPerBeat: automationSecondsPerBeat,
            pitchOverride: overlay?.sourcePitch[source.id],
            cutoffOverride: overlay?.sourceCutoff[source.id])
    }

    private func beatValue(_ time: MusicalTime) throws -> Double {
        let value = Double(time.numerator) / Double(time.denominator)
        guard value.isFinite else { throw LoopRenderingError.overflow }
        return value
    }
}
