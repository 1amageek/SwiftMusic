import Foundation
import SwiftMusic

/// RBJ biquads: https://www.w3.org/TR/audio-eq-cookbook/
internal struct VoiceFilter: Equatable {
    private struct Section: Equatable {
        var z1 = 0.0
        var z2 = 0.0
        mutating func process(_ input: Double, b0: Double, b1: Double, b2: Double,
                              a1: Double, a2: Double) -> Double {
            let output = b0 * input + z1
            z1 = b1 * input - a1 * output + z2
            z2 = b2 * input - a2 * output
            return output
        }
    }

    let descriptor: SourceFilter
    private var first = Section()
    private var second = Section()
    private var third = Section()
    private var fourth = Section()
    private var previousCutoff: Double?
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    init(_ descriptor: SourceFilter) { self.descriptor = descriptor }

    mutating func process(_ input: Double, cutoff: Double, eventIndex: Int) throws -> Double {
        guard cutoff.isFinite, cutoff > 0, cutoff < PreparedLoop.requiredSampleRate / 2 else {
            throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "cutoff must be below Nyquist")
        }
        if previousCutoff != cutoff {
            let omega = 2 * Double.pi * cutoff / PreparedLoop.requiredSampleRate
            let cosine = cos(omega)
            let alpha = sin(omega) / (2 * descriptor.resonanceQ)
            let a0 = 1 + alpha
            switch descriptor.kind {
            case .lowPass:
                b0 = (1 - cosine) / (2 * a0); b1 = (1 - cosine) / a0; b2 = b0
            case .highPass:
                b0 = (1 + cosine) / (2 * a0); b1 = -(1 + cosine) / a0; b2 = b0
            case .bandPass:
                b0 = alpha / a0; b1 = 0; b2 = -b0
            case .notch:
                throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "unsupported source filter kind")
            }
            a1 = -2 * cosine / a0
            a2 = (1 - alpha) / a0
            previousCutoff = cutoff
        }
        var output = first.process(input, b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
        if descriptor.slope == .twentyFour || descriptor.kind == .bandPass {
            output = second.process(output, b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
        }
        if descriptor.kind == .bandPass, descriptor.slope == .twentyFour {
            output = third.process(output, b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
            output = fourth.process(output, b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
        }
        guard third.z1.isFinite, third.z2.isFinite, fourth.z1.isFinite, fourth.z2.isFinite,
              output.isFinite, first.z1.isFinite, first.z2.isFinite,
              second.z1.isFinite, second.z2.isFinite else {
            throw LoopRenderingError.invalidEvent(index: eventIndex, reason: "non-finite source filter state")
        }
        return output
    }
}
