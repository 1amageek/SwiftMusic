import Accelerate
import Foundation

/// Performs bounded real-valued convolution through cached Accelerate DFT setups.
internal final class FFTConvolver {
    // Pad tiny convolutions to at least two frames so the native setup path has
    // a nonzero power-of-two transform, including for a one-frame convolution.
    private static let minimumTransformLength = 2
    private static let maximumTransformLength = 2_097_152
    private static let maximumScratchBytes = 48 * 1024 * 1024

    private struct SetupPair {
        let forward: vDSP_DFT_Setup
        let inverse: vDSP_DFT_Setup
    }

    private let maximumLinearFrameCount: Int
    private var setups: [Int: SetupPair] = [:]

    init(maximumLinearFrameCount: Int) throws {
        guard maximumLinearFrameCount > 0,
              let transformLength = Self.nextPowerOfTwo(maximumLinearFrameCount),
              transformLength <= Self.maximumTransformLength,
              transformLength <= Self.maximumScratchBytes / (MemoryLayout<Float>.stride * 6) else {
            throw LoopRenderingError.invalidSound("FFT convolution frame bound is invalid")
        }
        self.maximumLinearFrameCount = maximumLinearFrameCount
    }

    deinit {
        // The cache owns each native setup pair and is the sole destruction owner.
        for pair in setups.values {
            vDSP_DFT_DestroySetup(pair.forward)
            vDSP_DFT_DestroySetup(pair.inverse)
        }
    }

    func convolve(
        _ input: [Float],
        with impulse: [Float],
        outputFrameCount: Int,
        circular: Bool
    ) throws -> [Float] {
        guard !input.isEmpty, !impulse.isEmpty else {
            throw LoopRenderingError.invalidSound("FFT convolution input must not be empty")
        }
        guard outputFrameCount > 0, outputFrameCount <= maximumLinearFrameCount else {
            throw LoopRenderingError.invalidSound("FFT convolution output frame count is out of bounds")
        }
        guard input.allSatisfy(\.isFinite), impulse.allSatisfy(\.isFinite) else {
            throw LoopRenderingError.invalidSound("FFT convolution input must be finite")
        }

        let (sum, overflow) = input.count.addingReportingOverflow(impulse.count)
        guard !overflow, sum > 0 else {
            throw LoopRenderingError.invalidSound("FFT convolution input length overflow")
        }
        let naturalLength = sum - 1
        guard naturalLength > 0, naturalLength <= maximumLinearFrameCount,
              let transformLength = Self.nextPowerOfTwo(naturalLength),
              transformLength <= Self.maximumTransformLength,
              transformLength <= Self.maximumScratchBytes / (MemoryLayout<Float>.stride * 6) else {
            throw LoopRenderingError.invalidSound("FFT convolution transform length is out of bounds")
        }

        let pair = try setup(for: transformLength)

        // Six transform buffers are the complete scratch workspace: the input and
        // impulse complex pairs, with the impulse pair reused for inverse output,
        // plus the complex product pair.
        var inputReal = [Float](repeating: 0, count: transformLength)
        var inputImaginary = [Float](repeating: 0, count: transformLength)
        var impulseReal = [Float](repeating: 0, count: transformLength)
        var impulseImaginary = [Float](repeating: 0, count: transformLength)
        var productReal = [Float](repeating: 0, count: transformLength)
        var productImaginary = [Float](repeating: 0, count: transformLength)
        inputReal.replaceSubrange(input.indices, with: input)
        impulseReal.replaceSubrange(impulse.indices, with: impulse)

        // vDSP borrows these array pointers only for each synchronous call; no
        // pointer escapes the call and the Swift arrays remain the owners.
        vDSP_DFT_Execute(
            pair.forward,
            inputReal,
            inputImaginary,
            &productReal,
            &productImaginary
        )
        guard productReal.allSatisfy(\.isFinite), productImaginary.allSatisfy(\.isFinite) else {
            throw LoopRenderingError.invalidSound("FFT convolution input transform is non-finite")
        }

        vDSP_DFT_Execute(
            pair.forward,
            impulseReal,
            impulseImaginary,
            &inputReal,
            &inputImaginary
        )
        guard inputReal.allSatisfy(\.isFinite), inputImaginary.allSatisfy(\.isFinite) else {
            throw LoopRenderingError.invalidSound("FFT convolution impulse transform is non-finite")
        }

        for index in 0..<transformLength {
            let real = productReal[index] * inputReal[index]
                - productImaginary[index] * inputImaginary[index]
            let imaginary = productReal[index] * inputImaginary[index]
                + productImaginary[index] * inputReal[index]
            guard real.isFinite, imaginary.isFinite else {
                throw LoopRenderingError.invalidSound("FFT convolution spectrum product is non-finite")
            }
            productReal[index] = real
            productImaginary[index] = imaginary
        }

        vDSP_DFT_Execute(
            pair.inverse,
            productReal,
            productImaginary,
            &impulseReal,
            &impulseImaginary
        )

        let scale = 1 / Float(transformLength)
        var output = [Float](repeating: 0, count: outputFrameCount)
        if circular {
            for index in 0..<naturalLength {
                let value = impulseReal[index] * scale
                guard value.isFinite else {
                    throw LoopRenderingError.invalidSound("FFT convolution output is non-finite")
                }
                let destination = index % outputFrameCount
                let sum = output[destination] + value
                guard sum.isFinite else {
                    throw LoopRenderingError.invalidSound("FFT convolution output is non-finite")
                }
                output[destination] = sum
            }
        } else {
            for index in 0..<min(naturalLength, outputFrameCount) {
                let value = impulseReal[index] * scale
                guard value.isFinite else {
                    throw LoopRenderingError.invalidSound("FFT convolution output is non-finite")
                }
                output[index] = value
            }
        }
        return output
    }

    private func setup(for length: Int) throws -> SetupPair {
        if let cached = setups[length] {
            return cached
        }
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(length), .FORWARD) else {
            throw LoopRenderingError.invalidSound("Accelerate FFT setup is unavailable")
        }
        guard let inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(length), .INVERSE) else {
            vDSP_DFT_DestroySetup(forward)
            throw LoopRenderingError.invalidSound("Accelerate inverse FFT setup is unavailable")
        }
        let pair = SetupPair(forward: forward, inverse: inverse)
        setups[length] = pair
        return pair
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int? {
        guard value > 0 else { return nil }
        var result = minimumTransformLength
        while result < value {
            if result > maximumTransformLength / 2 { return nil }
            result *= 2
        }
        return result
    }
}
