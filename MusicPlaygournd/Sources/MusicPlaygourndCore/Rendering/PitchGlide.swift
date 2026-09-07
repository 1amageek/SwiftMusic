import Foundation
import SwiftMusic

/// Shared pitch trajectory for oscillator phase, sample traversal and exhaustion analysis.
internal enum PitchGlide {
    static func midi(event: CompiledSoundEvent, source: CompiledSource,
                     time: Double, secondsPerBeat: Double) throws -> Double {
        let target = Double(event.pitch?.midiNote ?? 60) + event.pitchOffsetSemitones
        guard let setting = source.portamento, let start = event.portamentoStartMIDINote else { return target }
        let seconds: Double
        switch setting.duration {
        case .seconds(let duration):
            let parts = duration.components
            seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        case .beats(let duration):
            seconds = Double(duration.numerator) / Double(duration.denominator) * secondsPerBeat
        }
        guard seconds.isFinite, seconds > 0, start.isFinite, (0...127).contains(start) else {
            throw LoopRenderingError.invalidSound("invalid portamento trajectory")
        }
        let progress = min(1, max(0, time / seconds))
        return progress == 1 ? target : start + (target - start) * progress
    }
}
