import Foundation
import SwiftMusic

internal enum ControlVisualizationRenderer {
    static func render(sound: CompiledSound, loop: PreparedLoop, samples: SamplePreparation,
                       descriptor: LiveControlDescriptor, overlay: RenderControlOverlay?) throws -> PreparedControlVisualization {
        let address = descriptor.address
        guard let presentation = descriptor.presentation else { throw ControlVisualizationError.unsupported(address) }
        let rate = PreparedLoop.requiredSampleRate
        let secondsPerBeat = 60 / loop.bpm
        let window = beats(sound.extent)
        let automationClock = sound.playbackMode == .seamlessLoop
            ? ceil(window * secondsPerBeat * rate) / rate / window : secondsPerBeat
        var remaining = PreparedControlVisualization.maximumPoints
        let selectedEvents = sound.events.indices.filter {
            if case .source(let id) = address.target { return sound.events[$0].sourceID == id }
            return false
        }
        let resolution = min(128, max(2, remaining / max(1, selectedEvents.count * 4)))

        func channel(_ kind: PreparedControlTrace.Channel.Kind, start: Double, duration: Double,
                     boundaries: [Double] = [], signal: AutomationSignal? = nil,
                     value: (Double) throws -> Double) throws -> PreparedControlTrace.Channel {
            let limit = min(512, remaining)
            guard limit >= 2 else { throw ControlVisualizationError.pointLimit }
            var times: Set<Double> = [0, duration]
            func insert(_ time: Double) throws {
                if time > 0, time < duration {
                    times.insert(time)
                    guard times.count <= limit else { throw ControlVisualizationError.pointLimit }
                }
            }
            for boundary in boundaries { try insert(boundary) }
            // Retain the canonical loop crossing even when a voice continues beyond beat zero.
            try insert(loop.beatCount * secondsPerBeat - start)
            if let signal {
                let period: Double
                let phases: [Double]
                switch signal {
                case .steps(let steps):
                    period = beats(steps.cycle) * automationClock
                    guard steps.values.count <= limit else { throw ControlVisualizationError.pointLimit }
                    phases = steps.values.indices.map { Double($0) / Double(steps.values.count) }
                case .curve(let curve):
                    period = beats(curve.cycle) * automationClock
                    guard curve.points.count <= limit else { throw ControlVisualizationError.pointLimit }
                    phases = curve.points.map { beats($0.position) / beats(curve.cycle) }
                case .lfo(let lfo):
                    switch lfo.rate {
                    case .hertz(let frequency): period = 1 / frequency.hertz
                    case .synchronized(let time): period = beats(time) * automationClock
                    }
                    phases = [0, 0.25, 0.5, 0.75].map { $0 - lfo.phase }
                }
                let first = floor(start / period) - 1
                let last = ceil((start + duration) / period) + 1
                guard first.isFinite, last.isFinite, last - first <= Double(limit),
                      abs(first) < Double(Int.max / 2), abs(last) < Double(Int.max / 2) else {
                    throw ControlVisualizationError.pointLimit
                }
                for cycle in Int(first)...Int(last) {
                    for phase in phases {
                        let time = (Double(cycle) + phase) * period - start
                        if time > 0, time < duration {
                            try insert(time)
                            // A neighboring frame shows discontinuous step edges without smoothing them away.
                            try insert(time - 1 / rate)
                        }
                    }
                }
            }
            let available = min(resolution, limit - times.count)
            if available > 0 {
                for index in 1...available { try insert(duration * Double(index) / Double(available + 1)) }
            }
            remaining -= times.count
            let points = try times.sorted().map {
                PreparedControlTrace.Channel.Point(beat: (start + $0) / secondsPerBeat, value: try value($0))
            }
            return .init(kind: kind, points: points)
        }

        var traces: [PreparedControlTrace] = []
        switch address.target {
        case .master:
            throw ControlVisualizationError.unsupported(address)
        case .source(let id):
            let source = sound.sources[id]
            for index in selectedEvents {
                try Task.checkCancellation()
                let event = sound.events[index]
                let start = beats(event.start) * secondsPerBeat
                let natural = beats(event.duration) * secondsPerBeat
                let amplitude = VoiceEnvelope.amplitude(event: event, source: source, secondsPerBeat: secondsPerBeat)
                let pitch = source.pitchEnvelope.map { VoiceEnvelope($0.envelope, noteDuration: natural, gate: event.gate) }
                let filter = source.filterEnvelope.map { VoiceEnvelope($0.envelope, noteDuration: natural, gate: event.gate) }
                var duration = loop.events[index].durationBeats * secondsPerBeat
                if let sample = samples.voices[index] {
                    let available = sound.playbackMode == .seamlessLoop ? window * secondsPerBeat
                        : max(0, min(PreparedLoop.maximumDurationSeconds, PreparedLoop.maximumBeatCount * secondsPerBeat) - start)
                    let frames = try sample.frames(event: event, source: source, secondsPerBeat: secondsPerBeat,
                        limit: Int((available * rate).rounded(.down)), automationSecondsPerBeat: automationClock,
                        pitchAutomationOverride: overlay?.sourcePitch[id])
                    duration = Double(frames) / rate
                    if sound.playbackMode == .finite { duration = min(duration, loop.beatCount * secondsPerBeat - start) }
                }
                var boundaries = [Double]()
                for contour in [amplitude, pitch, filter].compactMap({ $0 }) {
                    boundaries += [contour.envelope.attackSeconds,
                        contour.envelope.attackSeconds + contour.envelope.decaySeconds, contour.anchor, contour.duration]
                }
                if let portamento = source.portamento {
                    switch portamento.duration {
                    case .seconds(let duration):
                        let parts = duration.components
                        boundaries.append(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
                    case .beats(let duration): boundaries.append(beats(duration) * secondsPerBeat)
                    }
                }
                let signal: AutomationSignal?
                switch address.parameter {
                case .pitchOffsetSemitones: signal = overlay?.sourcePitch[id] == nil ? source.pitchAutomation?.signal : nil
                case .cutoffHz: signal = overlay?.sourceCutoff[id] == nil ? source.cutoffAutomation?.signal : nil
                default: signal = nil
                }
                let startFrame = Int((start * rate).rounded(.down))
                var channels = [try channel(.selectedValue, start: start, duration: duration,
                    boundaries: boundaries, signal: signal) { time in
                    let frame = startFrame + Int((time * rate).rounded(.down))
                    switch address.parameter {
                    case .gain: return event.gain * (overlay?.sourceGain[id] ?? 1)
                    case .pan:
                        guard let value = overlay?.sourcePan[id] ?? event.pan else {
                            throw ControlVisualizationError.unsupported(address)
                        }
                        return value
                    case .pitchOffsetSemitones:
                        var value = try PitchGlide.midi(event: event, source: source, time: time, secondsPerBeat: secondsPerBeat)
                        if let offset = overlay?.sourcePitch[id] { value += offset }
                        else if let automation = source.pitchAutomation {
                            value += try AutomationEvaluator.mapped(automation.signal, from: automation.from.value,
                                to: automation.to.value, frame: frame, secondsPerBeat: automationClock)
                        }
                        return value + (source.pitchEnvelope?.depth.value ?? 0) * (pitch?.value(at: time) ?? 0)
                    case .cutoffHz:
                        let cutoff: Double
                        if let value = overlay?.sourceCutoff[id] { cutoff = value }
                        else if let automation = source.cutoffAutomation {
                            cutoff = try AutomationEvaluator.mapped(automation.signal, from: automation.from.hertz,
                                to: automation.to.hertz, frame: frame, secondsPerBeat: automationClock)
                        } else if let value = event.cutoffHz { cutoff = value }
                        else { throw ControlVisualizationError.unsupported(address) }
                        return cutoff * pow(2, (source.filterEnvelope?.depth.value ?? 0) * (filter?.value(at: time) ?? 0) / 12)
                    default: throw ControlVisualizationError.unsupported(address)
                    }
                }]
                for (kind, contour, depth) in [
                    (PreparedControlTrace.Channel.Kind.amplitudeEnvelope, amplitude, 1.0),
                    (.pitchEnvelope, pitch, source.pitchEnvelope?.depth.value ?? 0),
                    (.filterEnvelope, filter, source.filterEnvelope?.depth.value ?? 0)
                ] {
                    if let contour {
                        channels.append(try channel(kind, start: start, duration: duration,
                            boundaries: boundaries) { depth * contour.value(at: $0) })
                    }
                }
                let startBeat = start / secondsPerBeat
                let durationBeats = duration / secondsPerBeat
                traces.append(.init(eventIndex: index, sourceID: id, startBeat: startBeat,
                    durationBeats: durationBeats, wrapsLoopBoundary: startBeat + durationBeats > loop.beatCount,
                    channels: channels))
            }
        case .track(let id):
            let value: Double?
            switch address.parameter {
            case .trackMute: value = (overlay?.trackMute[id] ?? sound.tracks[id].isMuted) ? 1 : 0
            case .trackLevel: value = overlay?.trackLevel[id] ?? sound.tracks[id].level
            case .trackPan: value = overlay.map { $0.effectiveTrackPan(id, baseline: sound.tracks[id].pan) } ?? sound.tracks[id].pan
            default: value = nil
            }
            guard let value else { throw ControlVisualizationError.unsupported(address) }
            traces = [.init(eventIndex: nil, sourceID: nil, startBeat: 0, durationBeats: loop.beatCount,
                wrapsLoopBoundary: false, channels: [try channel(.selectedValue, start: 0,
                    duration: loop.beatCount * secondsPerBeat) { _ in value }])]
        case .renderNode(let id):
            let signal: AutomationSignal?
            let from: Double
            let to: Double
            let override: Double?
            switch sound.renderNodes[id] {
            case .gain(_, let value): signal = nil; from = value; to = value; override = overlay?.nodeGain[id]
            case .pan(_, let value): signal = nil; from = value; to = value; override = overlay?.nodePan[id]
            case .gainAutomation(_, let automation):
                signal = automation.signal; from = automation.from; to = automation.to; override = overlay?.nodeGain[id]
            case .panAutomation(_, let automation):
                signal = automation.signal; from = automation.from; to = automation.to; override = overlay?.nodePan[id]
            default: throw ControlVisualizationError.unsupported(address)
            }
            traces = [.init(eventIndex: nil, sourceID: nil, startBeat: 0, durationBeats: loop.beatCount,
                wrapsLoopBoundary: false, channels: [try channel(.selectedValue, start: 0,
                    duration: loop.beatCount * secondsPerBeat, signal: override == nil ? signal : nil) { time in
                    if let override { return override }
                    guard let signal else { return from }
                    return try AutomationEvaluator.mapped(signal, from: from, to: to,
                        frame: Int((time * rate).rounded(.down)), secondsPerBeat: automationClock)
                }])]
        }
        return try PreparedControlVisualization(address: address, unit: presentation.unit,
            beatCount: loop.beatCount, traces: traces)
    }

    private static func beats(_ value: MusicalTime) -> Double {
        Double(value.numerator) / Double(value.denominator)
    }
}
