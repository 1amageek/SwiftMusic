import Foundation
import SwiftMusic

/// RBJ peaking EQ with a solved periodic state for circular input.
internal struct PeakingEqualizer {
    private let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    init(frequency: Double, gain: Double, q: Double) throws {
        guard frequency.isFinite, frequency > 0, frequency < PreparedLoop.requiredSampleRate / 2,
              gain.isFinite, q.isFinite, q > 0 else {
            throw LoopRenderingError.invalidSound("invalid peaking EQ parameters")
        }
        let amplitude = pow(10, gain / 40)
        let omega = 2 * Double.pi * frequency / PreparedLoop.requiredSampleRate
        let alpha = sin(omega) / (2 * q)
        let a0 = 1 + alpha / amplitude
        b0 = (1 + alpha * amplitude) / a0
        b1 = -2 * cos(omega) / a0
        b2 = (1 - alpha * amplitude) / a0
        a1 = b1
        a2 = (1 - alpha / amplitude) / a0
        guard [b0, b1, b2, a1, a2].allSatisfy({ $0.isFinite }) else {
            throw LoopRenderingError.invalidSound("non-finite EQ coefficients")
        }
    }

    init(filter kind: FilterKind, cutoff: Double, resonance: Double) throws {
        guard cutoff.isFinite, cutoff > 0, cutoff < PreparedLoop.requiredSampleRate / 2,
              resonance.isFinite, resonance >= 0 else {
            throw LoopRenderingError.invalidSound("invalid post-mix filter")
        }
        let omega = 2 * Double.pi * cutoff / PreparedLoop.requiredSampleRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * (0.5 + resonance))
        let a0 = 1 + alpha
        switch kind {
        case .lowPass:
            b0 = (1 - cosine) / (2 * a0); b1 = (1 - cosine) / a0; b2 = b0
        case .highPass:
            b0 = (1 + cosine) / (2 * a0); b1 = -(1 + cosine) / a0; b2 = b0
        case .bandPass:
            b0 = alpha / a0; b1 = 0; b2 = -b0
        case .notch:
            b0 = 1 / a0; b1 = -2 * cosine / a0; b2 = b0
        }
        a1 = -2 * cosine / a0
        a2 = (1 - alpha) / a0
    }

    private func advance(_ input: Double, _ z1: inout Double, _ z2: inout Double) throws -> Double {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        guard output.isFinite, z1.isFinite, z2.isFinite else { throw LoopRenderingError.invalidSound("non-finite EQ state") }
        return output
    }

    func process(_ samples: inout [Float], horizon: Int, circular: Bool) throws {
        let count = circular ? samples.count : horizon
        guard count >= 0, count <= samples.count else { throw LoopRenderingError.invalidSound("invalid EQ horizon") }
        var z1 = 0.0, z2 = 0.0
        if circular {
            for input in samples { _ = try advance(Double(input), &z1, &z2) }
            var power = Matrix(a: -a1, b: 1, c: -a2, d: 0)
            var transition = Matrix(a: 1, b: 0, c: 0, d: 1)
            var exponent = count
            while exponent > 0 {
                if exponent & 1 == 1 { transition = transition * power }
                exponent >>= 1
                if exponent > 0 { power = power * power }
            }
            let determinant = (1 - transition.a) * (1 - transition.d) - transition.b * transition.c
            guard determinant.isFinite, determinant != 0 else { throw LoopRenderingError.invalidSound("singular periodic EQ state") }
            let first = ((1 - transition.d) * z1 + transition.b * z2) / determinant
            let second = (transition.c * z1 + (1 - transition.a) * z2) / determinant
            guard first.isFinite, second.isFinite else { throw LoopRenderingError.invalidSound("non-finite periodic EQ state") }
            z1 = first; z2 = second
        }
        let initial1 = z1, initial2 = z2
        for index in 0..<count {
            let output = try advance(Double(samples[index]), &z1, &z2)
            guard abs(output) <= Double(Float.greatestFiniteMagnitude) else { throw LoopRenderingError.invalidSound("EQ PCM exceeds Float range") }
            samples[index] = Float(output)
        }
        if circular {
            let scale = max(1, max(abs(initial1), abs(initial2)))
            guard abs(z1 - initial1) <= 1e-12 * scale, abs(z2 - initial2) <= 1e-12 * scale else {
                throw LoopRenderingError.invalidSound("unverified periodic biquad state")
            }
        }
    }

    private struct Matrix {
        let a: Double, b: Double, c: Double, d: Double
        static func * (lhs: Self, rhs: Self) -> Self {
            Self(a: lhs.a * rhs.a + lhs.b * rhs.c, b: lhs.a * rhs.b + lhs.b * rhs.d,
                 c: lhs.c * rhs.a + lhs.d * rhs.c, d: lhs.c * rhs.b + lhs.d * rhs.d)
        }
    }
}
