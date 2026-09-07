import Foundation
import SwiftMusic

/// One voice's contour, including release from the level reached at its anchor.
internal struct VoiceEnvelope {
    let envelope: Envelope
    let anchor: Double
    var duration: Double { anchor + envelope.releaseSeconds }

    init(_ envelope: Envelope, noteDuration: Double, gate: Double) {
        self.envelope = envelope
        anchor = envelope.releaseAnchor == .gateEnd ? noteDuration * gate : noteDuration
    }

    static func amplitude(event: CompiledSoundEvent, source: CompiledSource,
                          secondsPerBeat: Double) -> Self? {
        (event.envelope ?? source.envelope).map {
            Self($0, noteDuration: Double(event.duration.numerator) / Double(event.duration.denominator)
                 * secondsPerBeat, gate: event.gate)
        }
    }

    func value(at time: Double) -> Double {
        guard time >= 0 else { return 0 }
        if time < anchor { return beforeRelease(at: time) }
        guard envelope.releaseSeconds > 0, time < duration else { return 0 }
        return interpolate(beforeRelease(at: anchor), 0,
                           (time - anchor) / envelope.releaseSeconds, envelope.releaseCurve)
    }

    private func beforeRelease(at time: Double) -> Double {
        if time < envelope.attackSeconds {
            return interpolate(0, 1, time / envelope.attackSeconds, envelope.attackCurve)
        }
        let decayTime = time - envelope.attackSeconds
        if decayTime < envelope.decaySeconds {
            return interpolate(1, envelope.sustainLevel, decayTime / envelope.decaySeconds,
                               envelope.decayCurve)
        }
        return envelope.sustainLevel
    }

    private func interpolate(_ start: Double, _ end: Double, _ fraction: Double,
                             _ curve: EnvelopeCurve) -> Double {
        let progress: Double
        switch curve {
        case .linear: progress = fraction
        case .exponential(let exponent): progress = pow(fraction, exponent)
        }
        return start + (end - start) * progress
    }
}
