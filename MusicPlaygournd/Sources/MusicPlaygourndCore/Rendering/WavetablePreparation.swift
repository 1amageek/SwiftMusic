import Accelerate
import SwiftMusic

/// Immutable octave tables share storage between every voice of one source.
internal struct WavetablePreparation: Sendable {
    struct Level: Sendable {
        let samples: [Float]
        let harmonics: Int
        func value(phase: Double) -> Double {
            let position = phase * Double(samples.count)
            let first = Int(position)
            let next = (first + 1) % samples.count
            return Double(samples[first]) + (Double(samples[next]) - Double(samples[first])) * (position - Double(first))
        }
    }
    let levels: [Level]
    var sampleCount: Int { levels.reduce(0) { $0 + $1.samples.count } }

    init(_ table: Wavetable) throws {
        let size = table.samples.count
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD) else {
            throw LoopRenderingError.invalidSound("wavetable forward transform unavailable")
        }
        defer { vDSP_DFT_DestroySetup(forward) }
        guard let inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .INVERSE) else {
            throw LoopRenderingError.invalidSound("wavetable inverse transform unavailable")
        }
        defer { vDSP_DFT_DestroySetup(inverse) }
        let zero = [Float](repeating: 0, count: size)
        var spectrumReal = zero
        var spectrumImaginary = zero
        vDSP_DFT_Execute(forward, table.samples, zero, &spectrumReal, &spectrumImaginary)
        var real = zero
        var imaginary = zero
        var reconstructed = zero
        var discardedImaginary = zero
        var levels: [Level] = []
        var harmonics = size / 2
        while harmonics >= 1 {
            for bin in 0..<size {
                let retain = bin <= harmonics || bin >= size - harmonics
                real[bin] = retain ? spectrumReal[bin] : 0
                imaginary[bin] = retain ? spectrumImaginary[bin] : 0
            }
            vDSP_DFT_Execute(inverse, real, imaginary, &reconstructed, &discardedImaginary)
            var samples = [Float](repeating: 0, count: size)
            for index in 0..<size {
                let value = reconstructed[index] / Float(size)
                guard value.isFinite else { throw LoopRenderingError.invalidSound("non-finite wavetable transform") }
                samples[index] = value
            }
            levels.append(Level(samples: samples, harmonics: harmonics))
            harmonics /= 2
        }
        guard levels.count <= 12, levels.reduce(0, { $0 + $1.samples.count }) <= 49_152 else {
            throw LoopRenderingError.invalidSound("wavetable mip storage exceeds limit")
        }
        self.levels = levels
    }

    func level(frequency: Double) -> Int {
        var index = 0
        while index + 1 < levels.count,
              Double(levels[index].harmonics) * frequency >= PreparedLoop.requiredSampleRate / 2 {
            index += 1
        }
        return index
    }
}
