import Foundation
import SwiftMusic

/// Projects semantic pitch; native tuning, unison and timbral settings remain instrument-owned.
internal enum MIDIPitchProjection {
    static func resolve(event: CompiledSoundEvent, source: CompiledSource, frames: Int,
                        secondsPerBeat: Double, automationSecondsPerBeat: Double,
                        override: Double?) throws -> MIDIEventProjection {
        guard event.pitch != nil else { return .none }
        switch source.kind {
        case .sample, .synthesizer(.noise), .synthesizer(.coloredNoise): return .none
        default: break
        }
        let contour = source.pitchEnvelope.map {
            VoiceEnvelope($0.envelope,
                noteDuration: Double(event.duration.numerator) / Double(event.duration.denominator) * secondsPerBeat,
                gate: event.gate)
        }
        let start = Int((Double(event.start.numerator) / Double(event.start.denominator)
            * secondsPerBeat * PreparedLoop.requiredSampleRate).rounded(.down))
        func pitch(frame: Int) throws -> Double {
            let time = Double(frame) / PreparedLoop.requiredSampleRate
            var value = try PitchGlide.midi(event: event, source: source, time: time, secondsPerBeat: secondsPerBeat)
            if let override { value += override }
            else if let automation = source.pitchAutomation {
                value += try AutomationEvaluator.mapped(automation.signal,
                    from: automation.from.value, to: automation.to.value,
                    frame: start + frame, secondsPerBeat: automationSecondsPerBeat)
            }
            if let contour { value += (source.pitchEnvelope?.depth.value ?? 0) * contour.value(at: time) }
            return value
        }
        let first = try pitch(frame: 0)
        let dynamic = source.portamento != nil || source.pitchEnvelope != nil
            || (override == nil && source.pitchAutomation != nil)
        if dynamic, frames > 1 {
            // Stop at the first audible-frame difference; static paths avoid this scan entirely.
            for frame in 1..<frames {
                if frame.isMultiple(of: 4096) { try Task.checkCancellation() }
                if try pitch(frame: frame) != first { return .unsupported(.timeVaryingPitch) }
            }
        }
        guard first.isFinite, (0...127).contains(first) else { return .unsupported(.outOfRange) }
        guard first.rounded() == first else { return .unsupported(.fractionalPitch) }
        return .note(Int(first))
    }
}
