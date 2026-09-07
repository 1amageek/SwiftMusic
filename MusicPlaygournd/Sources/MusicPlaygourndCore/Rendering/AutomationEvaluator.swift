import Foundation
import SwiftMusic

/// Evaluates immutable signals on the transport clock without allocating per frame.
internal enum AutomationEvaluator {
    static func validate(_ sound: CompiledSound, bpm: Double, windowBeats: Double) throws {
        let secondsPerBeat = 60 / bpm
        let seamless = sound.playbackMode == .seamlessLoop
        for source in sound.sources {
            if let pitch = source.pitchAutomation {
                try validate(pitch.signal, secondsPerBeat: secondsPerBeat, windowBeats: windowBeats, seamless: seamless, exactWindow: sound.extent)
            }
            if let cutoff = source.cutoffAutomation {
                try validate(cutoff.signal, secondsPerBeat: secondsPerBeat, windowBeats: windowBeats, seamless: seamless, exactWindow: sound.extent)
                let depth = source.filterEnvelope?.depth.value ?? 0
                for endpoint in [cutoff.from.hertz, cutoff.to.hertz] {
                    let shifted = endpoint * pow(2, depth / 12)
                    guard endpoint < PreparedLoop.requiredSampleRate / 2,
                          shifted.isFinite, shifted > 0, shifted < PreparedLoop.requiredSampleRate / 2 else {
                        throw LoopRenderingError.invalidSound("automated cutoff must remain below Nyquist")
                    }
                }
            }
        }
        for (index, event) in sound.events.enumerated() {
            guard sound.sources.indices.contains(event.sourceID) else {
                throw LoopRenderingError.invalidEvent(index: index, reason: "source ID is out of range")
            }
            let source = sound.sources[event.sourceID]
            if let automation = source.pitchAutomation {
                guard let pitch = event.pitch else {
                    throw LoopRenderingError.invalidEvent(index: index, reason: "pitch automation requires a pitched event")
                }
                let base = Double(pitch.midiNote) + event.pitchOffsetSemitones
                let depth = source.pitchEnvelope?.depth.value ?? 0
                for endpoint in [automation.from.value, automation.to.value] {
                    for envelope in [0, depth] {
                        let midi = base + endpoint + envelope
                        guard midi.isFinite, (0...127).contains(midi) else {
                            throw LoopRenderingError.invalidEvent(index: index, reason: "automated pitch exceeds MIDI range")
                        }
                    }
                }
            }
        }
        for node in sound.renderNodes {
            switch node {
            case .gainAutomation(_, let automation):
                try validate(automation.signal, secondsPerBeat: secondsPerBeat, windowBeats: windowBeats, seamless: seamless, exactWindow: sound.extent)
            case .panAutomation(_, let automation):
                try validate(automation.signal, secondsPerBeat: secondsPerBeat, windowBeats: windowBeats, seamless: seamless, exactWindow: sound.extent)
            default: break
            }
        }
    }

    static func value(_ signal: AutomationSignal, frame: Int, secondsPerBeat: Double) throws -> Double {
        let seconds = Double(frame) / PreparedLoop.requiredSampleRate
        func phase(period: MusicalTime) throws -> Double {
            try wrapped(seconds / (beats(period) * secondsPerBeat))
        }
        let position: Double
        switch signal {
        case .lfo(let lfo):
            switch lfo.rate {
            case .hertz(let frequency): position = try wrapped(seconds * frequency.hertz)
            case .synchronized(let period): position = try phase(period: period)
            }
        case .steps(let steps): position = try phase(period: steps.cycle)
        case .curve(let curve): position = try phase(period: curve.cycle)
        }
        return try signal.value(at: position)
    }

    static func mapped(_ signal: AutomationSignal, from: Double, to: Double,
                       frame: Int, secondsPerBeat: Double) throws -> Double {
        let normalized = try value(signal, frame: frame, secondsPerBeat: secondsPerBeat)
        let result = normalized == 1 ? to : from + normalized * (to - from)
        guard result.isFinite else { throw LoopRenderingError.invalidSound("non-finite automation value") }
        return result
    }

    static func validate(_ signal: AutomationSignal, secondsPerBeat: Double,
                         windowBeats: Double, seamless: Bool, exactWindow: MusicalTime) throws {
        let cycles: Double
        let synchronizedPeriod: MusicalTime?
        switch signal {
        case .lfo(let lfo):
            switch lfo.rate {
            case .hertz(let frequency):
                synchronizedPeriod = nil
                let frames = ceil(windowBeats * secondsPerBeat * PreparedLoop.requiredSampleRate)
                cycles = frequency.hertz * (seamless ? frames / PreparedLoop.requiredSampleRate : windowBeats * secondsPerBeat)
            case .synchronized(let period):
                synchronizedPeriod = period
                cycles = windowBeats / beats(period)
            }
        case .steps(let steps):
            synchronizedPeriod = steps.cycle
            cycles = windowBeats / beats(steps.cycle)
        case .curve(let curve):
            synchronizedPeriod = curve.cycle
            cycles = windowBeats / beats(curve.cycle)
        }
        guard cycles.isFinite, cycles > 0 else {
            throw LoopRenderingError.invalidSound("automation clock exceeds finite range")
        }
        if seamless {
            let divides: Bool
            if let period = synchronizedPeriod {
                // Both MusicalTime values are reduced fractions. Divisibility requires
                // only these remainders, avoiding both Double rounding and products.
                divides = exactWindow.numerator % period.numerator == 0
                    && period.denominator % exactWindow.denominator == 0
            } else {
                divides = cycles.rounded(.down) == cycles
            }
            guard divides else {
                throw LoopRenderingError.invalidSound("automation period must divide the seamless window")
            }
        }
    }

    private static func beats(_ value: MusicalTime) -> Double {
        Double(value.numerator) / Double(value.denominator)
    }

    private static func wrapped(_ value: Double) throws -> Double {
        guard value.isFinite else { throw LoopRenderingError.invalidSound("non-finite automation clock") }
        return value - floor(value)
    }
}
