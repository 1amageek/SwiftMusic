import Foundation
import SwiftMusic

/// One deterministic voice; immutable descriptors share sample storage while State owns DSP history.
internal struct RenderedVoice {
    struct State: Equatable {
        var offset = 0
        var phase = 0.0
        var samplePosition = 0.0
        var granular: GranularSampleVoice?
        var oscillator: PreparedOscillatorVoice?
        var filter: VoiceFilter?
        var rightFilter: VoiceFilter?
        var lastLeft: Float = 0
        var lastRight: Float = 0
    }
    let event: CompiledSoundEvent
    let source: CompiledSource
    let eventIndex: Int
    let startFrame: Int
    let eventFrames: Int
    let secondsPerBeat: Double
    let automationSecondsPerBeat: Double
    let sampleVoice: PreparedSampleVoice?
    let oscillator: OscillatorPreparation?
    let amplitudeEnvelope: VoiceEnvelope?
    let amplitude: Float
    let leftGain: Float
    let rightGain: Float
    let edgeFrames: Int
    let legacy: Bool
    let pitchContour: VoiceEnvelope?
    let filterContour: VoiceEnvelope?
    let pitchOverride: Double?
    let cutoffOverride: Double?
    let frequency: Double
    let fixedIncrement: Double?
    var state: State

    init(event: CompiledSoundEvent, source: CompiledSource, eventIndex: Int,
         startFrame: Int, eventFrames: Int, secondsPerBeat: Double,
         sampleVoice: PreparedSampleVoice?, amplitudeEnvelope: VoiceEnvelope?,
         oscillator: OscillatorPreparation? = nil,
         amplitude: Float, leftGain: Float, rightGain: Float, edgeFrames: Int,
         automationSecondsPerBeat: Double? = nil,
         pitchOverride: Double? = nil, cutoffOverride: Double? = nil) throws {
        self.event = event; self.source = source; self.eventIndex = eventIndex
        self.startFrame = startFrame; self.eventFrames = eventFrames; self.secondsPerBeat = secondsPerBeat
        self.automationSecondsPerBeat = automationSecondsPerBeat ?? secondsPerBeat
        self.sampleVoice = sampleVoice; self.amplitudeEnvelope = amplitudeEnvelope
        self.oscillator = oscillator
        self.amplitude = amplitude; self.leftGain = leftGain; self.rightGain = rightGain
        self.edgeFrames = edgeFrames
        self.pitchOverride = pitchOverride
        self.cutoffOverride = cutoffOverride
        legacy = source.portamento == nil && amplitudeEnvelope == nil && source.tuning == nil && source.pitchEnvelope == nil
            && source.pitchAutomation == nil && source.cutoffAutomation == nil
            && source.filter == nil && source.filterEnvelope == nil && event.pitchOffsetSemitones == 0
            && sampleVoice == nil && oscillator == nil && pitchOverride == nil && cutoffOverride == nil
        let naturalDuration = Double(event.duration.numerator) / Double(event.duration.denominator) * secondsPerBeat
        pitchContour = source.pitchEnvelope.map { VoiceEnvelope($0.envelope, noteDuration: naturalDuration, gate: event.gate) }
        filterContour = source.filterEnvelope.map { VoiceEnvelope($0.envelope, noteDuration: naturalDuration, gate: event.gate) }
        let midi = Double(event.pitch?.midiNote ?? 60) + event.pitchOffsetSemitones
        frequency = (source.tuning?.frequencyHz ?? 440)
            * pow(2, (midi - Double(source.tuning?.referencePitch.midiNote ?? 69)) / 12)
        fixedIncrement = try sampleVoice?.increment(event: event, source: source, time: 0,
            secondsPerBeat: secondsPerBeat, automationSecondsPerBeat: self.automationSecondsPerBeat,
            pitchAutomationOverride: pitchOverride)
        state = State(filter: source.filter.map(VoiceFilter.init), rightFilter: source.filter.map(VoiceFilter.init))
        if let configuration = source.granularPlayback {
            guard sampleVoice != nil else {
                throw LoopRenderingError.unsupportedSourceSetting(sourceID: source.id, setting: "granular requires decoded sample")
            }
            state.granular = try GranularSampleVoice(configuration, eventFrames: eventFrames,
                sourceID: source.id, eventIndex: eventIndex)
        }
        if !legacy, case .synthesizer = source.kind {
            if let pitchOverride {
                try validateFrequency(frequency * pow(2, pitchOverride / 12),
                    depth: source.pitchEnvelope?.depth.value ?? 0, eventIndex: eventIndex)
            } else if let automation = source.pitchAutomation {
                for endpoint in [automation.from.value, automation.to.value] {
                    try validateFrequency(frequency * pow(2, endpoint / 12),
                        depth: source.pitchEnvelope?.depth.value ?? 0, eventIndex: eventIndex)
                }
            } else {
                try validateFrequency(frequency, depth: source.pitchEnvelope?.depth.value ?? 0, eventIndex: eventIndex)
            }
        }
        if source.portamento != nil {
            guard event.pitch != nil else {
                throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "portamento requires pitch")
            }
            let start = try PitchGlide.midi(event: event, source: source, time: 0, secondsPerBeat: secondsPerBeat)
            for base in [start, midi] {
                for offset in [pitchOverride ?? source.pitchAutomation?.from.value ?? 0,
                               pitchOverride ?? source.pitchAutomation?.to.value ?? 0] {
                    let effective = base + offset
                    let depth = source.pitchEnvelope?.depth.value ?? 0
                    guard effective.isFinite, (0...127).contains(effective), (0...127).contains(effective + depth) else {
                        throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "portamento exceeds MIDI range")
                    }
                    let hz = (source.tuning?.frequencyHz ?? 440)
                        * pow(2, (effective - Double(source.tuning?.referencePitch.midiNote ?? 69)) / 12)
                    try validateFrequency(hz, depth: depth, eventIndex: eventIndex)
                }
            }
        }
        if source.filter != nil {
            guard let cutoff = event.cutoffHz else {
                throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "source filter requires event cutoff")
            }
            try validateFrequency(cutoffOverride ?? cutoff, depth: source.filterEnvelope?.depth.value ?? 0,
                                  eventIndex: eventIndex)
        }
        if let oscillator {
            let bases = [frequency, (source.tuning?.frequencyHz ?? 440) * pow(2,
                ((event.portamentoStartMIDINote ?? midi) - Double(source.tuning?.referencePitch.midiNote ?? 69)) / 12)]
            for base in bases {
                for offset in [pitchOverride ?? source.pitchAutomation?.from.value ?? 0,
                               pitchOverride ?? source.pitchAutomation?.to.value ?? 0] {
                    try oscillator.validate(frequency: base * pow(2, offset / 12))
                    try oscillator.validate(frequency: base * pow(2, (offset + (source.pitchEnvelope?.depth.value ?? 0)) / 12))
                }
            }
            state.oscillator = PreparedOscillatorVoice(oscillator)
        }
    }

    mutating func next() throws -> (left: Float, right: Float) {
        let index = eventIndex
        let offset = state.offset
        let time = Double(offset) / PreparedLoop.requiredSampleRate
        let transportFrame = startFrame + offset
        let edge = min(1, min(Double(offset + 1) / Double(edgeFrames), Double(eventFrames - offset) / Double(edgeFrames)))
        let left: Float
        let rightOutput: Float
        if legacy {
            let value = sample(source.kind, pitch: event.pitch, time: time) * amplitude * Float(edge)
            left = value * leftGain; rightOutput = value * rightGain
        } else {
            let pitchDepth = source.pitchEnvelope?.depth.value ?? 0
            let filterDepth = source.filterEnvelope?.depth.value ?? 0
            var raw: Double
            var right: Double?
            switch source.kind {
            case .synthesizer(let waveform):
                let automatedPitch: Double
                if let pitchOverride {
                    automatedPitch = pitchOverride
                } else if let automation = source.pitchAutomation {
                    automatedPitch = try AutomationEvaluator.mapped(automation.signal,
                        from: automation.from.value, to: automation.to.value,
                        frame: transportFrame, secondsPerBeat: automationSecondsPerBeat)
                } else {
                    automatedPitch = 0
                }
                let glideOffset = try source.portamento.map { _ in
                    try PitchGlide.midi(event: event, source: source, time: time, secondsPerBeat: secondsPerBeat)
                        - (Double(event.pitch?.midiNote ?? 60) + event.pitchOffsetSemitones)
                } ?? 0
                let currentFrequency = frequency * pow(2, (glideOffset + automatedPitch + pitchDepth * (pitchContour?.value(at: time) ?? 0)) / 12)
                let currentPhase = pitchContour == nil && pitchOverride == nil
                    && source.pitchAutomation == nil && source.portamento == nil
                    ? (time * frequency).truncatingRemainder(dividingBy: 1) : state.phase
                if let oscillator {
                    let sourceID = source.id
                    guard let value = try state.oscillator?.next(oscillator, frequency: currentFrequency,
                        sourceID: sourceID, eventIndex: index, offset: offset) else {
                        throw LoopRenderingError.invalidSound("oscillator state missing")
                    }
                    raw = value
                } else {
                    raw = Double(legacyOscillator(waveform, phase: currentPhase, time: time))
                }
                state.phase = (state.phase + currentFrequency / PreparedLoop.requiredSampleRate).truncatingRemainder(dividingBy: 1)
            case .sample:
                raw = Double(sample(source.kind, pitch: event.pitch, time: time))
            case .fileSample, .sampleBank:
                guard let sampleVoice, let fixedIncrement else {
                    throw LoopRenderingError.invalidSound("file event has no decoded sample")
                }
                let increment = source.pitchEnvelope == nil && source.pitchAutomation == nil && source.portamento == nil ? fixedIncrement
                    : try sampleVoice.increment(event: event, source: source, time: time,
                        secondsPerBeat: secondsPerBeat, automationSecondsPerBeat: automationSecondsPerBeat,
                        pitchAutomationOverride: pitchOverride)
                let scan = state.samplePosition
                let reversed = source.sampleReversed
                if let value = try state.granular?.next(sample: sampleVoice, offset: offset,
                    scan: scan, increment: increment, reversed: reversed) {
                    raw = value.0
                    right = value.1
                } else {
                    raw = sampleVoice.value(at: state.samplePosition, reversed: source.sampleReversed, channel: 0)
                    right = sampleVoice.value(at: state.samplePosition, reversed: source.sampleReversed, channel: 1)
                }
                state.samplePosition += increment
            }
            if state.filter != nil, let cutoff = event.cutoffHz {
                let automatedCutoff: Double
                if let cutoffOverride {
                    automatedCutoff = cutoffOverride
                } else if let automation = source.cutoffAutomation {
                    automatedCutoff = try AutomationEvaluator.mapped(automation.signal,
                        from: automation.from.hertz, to: automation.to.hertz,
                        frame: transportFrame, secondsPerBeat: automationSecondsPerBeat)
                } else {
                    automatedCutoff = cutoff
                }
                let frequency = automatedCutoff * pow(2, filterDepth * (filterContour?.value(at: time) ?? 0) / 12)
                if let filtered = try state.filter?.process(raw, cutoff: frequency, eventIndex: index) { raw = filtered }
                if let value = right, let filtered = try state.rightFilter?.process(value, cutoff: frequency, eventIndex: index) { right = filtered }
            }
            let contour = amplitudeEnvelope?.value(at: time) ?? edge
            let value = raw * Double(amplitude) * contour
            let rightValue = (right ?? raw) * Double(amplitude) * contour
            guard value.isFinite, abs(value) <= Double(Float.greatestFiniteMagnitude),
                  rightValue.isFinite, abs(rightValue) <= Double(Float.greatestFiniteMagnitude) else {
                throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "non-finite source PCM")
            }
            left = Float(value) * leftGain; rightOutput = Float(rightValue) * rightGain
        }
        state.offset += 1
        state.lastLeft = left; state.lastRight = rightOutput
        return (left, rightOutput)
    }

    private func sample(_ kind: SourceKind, pitch: Pitch?, time: Double) -> Float {
        switch kind {
        case .synthesizer(let waveform):
            let midi = Double(pitch?.midiNote ?? 60)
            let frequency = 440 * pow(2, (midi - 69) / 12)
            let phase = (time * frequency).truncatingRemainder(dividingBy: 1)
            return legacyOscillator(waveform, phase: phase, time: time)
        case .fileSample, .sampleBank:
            preconditionFailure("Decoded file voices use the sample traversal path")
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

    private func legacyOscillator(_ waveform: Waveform, phase: Double, time: Double) -> Float {
        switch waveform {
        case .sine: Float(sin(2 * .pi * phase))
        case .square: phase < 0.5 ? 1 : -1
        case .saw: Float(2 * phase - 1)
        case .triangle: Float(1 - 4 * abs((phase - 0.5).rounded() - (phase - 0.5)))
        case .noise: deterministicNoise(time: time)
        case .bandLimitedSaw, .pulse, .frequencyModulation, .coloredNoise, .wavetable:
            preconditionFailure("Advanced oscillators require prepared state")
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

}
