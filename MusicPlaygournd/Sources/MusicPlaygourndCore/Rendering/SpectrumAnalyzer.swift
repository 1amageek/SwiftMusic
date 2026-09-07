import Accelerate
import Foundation

/// Analyzes stereo PCM outside the audio callback.
@MainActor
public final class SpectrumAnalyzer {
    public enum Failure: Error { case unavailable }
    public static let size = 2048
    public static let bandCount = 96
    private let setup: vDSP_DFT_Setup
    private let window: [Float]
    private var input = [Float](repeating: 0, count: size)
    private let imaginary = [Float](repeating: 0, count: size)
    private var realOutput = [Float](repeating: 0, count: size)
    private var imaginaryOutput = [Float](repeating: 0, count: size)
    private var power = [Float](repeating: 0, count: size / 2 + 1)
    private let normalization: Float

    public init() throws {
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.size), .FORWARD) else {
            throw Failure.unavailable
        }
        self.setup = setup
        window = (0..<Self.size).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(Self.size)) }
        normalization = 4 / pow(Float(Self.size) / 2, 2)
    }

    isolated deinit { vDSP_DFT_DestroySetup(setup) }

    /// Returns peak-amplitude dBFS for logarithmic bands, with silence at -90 dBFS.
    public func analyze(loop: PreparedLoop, beat: Double, isPlaying: Bool) -> [Float] {
        let frames = loop.samples.count / 2
        let phase = beat.isFinite && loop.beatCount > 0 ? max(0, min(1, beat / loop.beatCount)) : 0
        return analyze(samples: loop.samples, sampleRate: loop.sampleRate,
            cursor: Int(phase * Double(frames)), isPlaying: isPlaying && beat.isFinite)
    }

    /// Analyzes the latest owned post-effect capture, using its actual device sample rate.
    public func analyze(interleavedSamples: [Float], sampleRate: Double, isPlaying: Bool) -> [Float] {
        analyze(samples: interleavedSamples, sampleRate: sampleRate,
            cursor: interleavedSamples.count / 2, isPlaying: isPlaying)
    }

    private func analyze(samples: [Float], sampleRate: Double, cursor: Int, isPlaying: Bool) -> [Float] {
        var bands = [Float](repeating: -90, count: Self.bandCount)
        let frames = samples.count / 2
        guard isPlaying, frames > 0, samples.count.isMultiple(of: 2),
              sampleRate.isFinite, sampleRate > 0 else { return bands }
        for index in power.indices { power[index] = 0 }
        for channel in 0..<2 {
            for index in 0..<Self.size {
                let frame = ((cursor - Self.size + index) % frames + frames) % frames
                input[index] = samples[frame * 2 + channel] * window[index]
            }
            // Accelerate borrows these arrays only for this call; the setup owns no sample pointers.
            vDSP_DFT_Execute(setup, input, imaginary, &realOutput, &imaginaryOutput)
            for index in power.indices {
                power[index] += (realOutput[index] * realOutput[index] + imaginaryOutput[index] * imaginaryOutput[index]) * normalization / 2
            }
        }
        for band in bands.indices {
            let low = 20 * pow(1000.0, Double(band) / Double(Self.bandCount))
            let high = 20 * pow(1000.0, Double(band + 1) / Double(Self.bandCount))
            let first = max(1, Int(ceil(low * Double(Self.size) / sampleRate)))
            let last = min(Self.size / 2, Int(ceil(high * Double(Self.size) / sampleRate)))
            guard first < last else { continue }
            var maximum: Float = 0
            for index in first..<last { maximum = max(maximum, power[index]) }
            bands[band] = min(0, max(-90, 10 * log10(max(maximum, 1e-9))))
        }
        return bands
    }
}
