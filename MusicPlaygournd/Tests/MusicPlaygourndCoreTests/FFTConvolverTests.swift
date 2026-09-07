import Testing
@testable import MusicPlaygourndCore

struct FFTConvolverTests {
    @Test(.timeLimit(.minutes(3)))
    func linearConvolutionMatchesIndependentNaiveFixture() throws {
        let input: [Float] = [0.25, -1, 2, 0.5]
        let impulse: [Float] = [1, -0.25, 0.5]
        let expected = naiveConvolution(input, impulse)
        let actual = try FFTConvolver(maximumLinearFrameCount: expected.count)
            .convolve(input, with: impulse, outputFrameCount: expected.count, circular: false)

        #expect(actual.count == expected.count)
        #expect(actual.enumerated().allSatisfy { index, value in
            abs(value - expected[index]) < 0.0001
        })
    }

    @Test(.timeLimit(.minutes(3)))
    func impulseAndFiniteOutputClippingPreserveTheLinearPath() throws {
        let input: [Float] = [0.25, -1, 2, 0.5]
        let impulse: [Float] = [1]
        let convolver = try FFTConvolver(maximumLinearFrameCount: input.count)

        let actual = try convolver.convolve(input, with: impulse, outputFrameCount: 2, circular: false)
        #expect(actual == Array(input.prefix(2)))

        let repeated = try convolver.convolve(input, with: impulse, outputFrameCount: input.count, circular: false)
        #expect(repeated.enumerated().allSatisfy { index, value in
            abs(value - input[index]) < 0.0001
        })

        let tiny = try FFTConvolver(maximumLinearFrameCount: 1)
        #expect(try tiny.convolve([2], with: [3], outputFrameCount: 1, circular: false) == [6])
    }

    @Test(.timeLimit(.minutes(3)))
    func circularConvolutionFoldsEveryLinearFrameByOutputPeriod() throws {
        let convolver = try FFTConvolver(maximumLinearFrameCount: 8)
        let actual = try convolver.convolve(
            [Float(1), 2, 3],
            with: [Float(4), 5],
            outputFrameCount: 3,
            circular: true
        )

        #expect(actual.enumerated().allSatisfy { index, value in
            abs(value - [19, 13, 22][index]) < 0.0001
        })
    }

    @Test(.timeLimit(.minutes(3)))
    func invalidBoundsAndInputsFailBeforeConvolution() throws {
        #expect(throws: LoopRenderingError.invalidSound("FFT convolution frame bound is invalid")) {
            try FFTConvolver(maximumLinearFrameCount: 0)
        }
        #expect(throws: LoopRenderingError.invalidSound("FFT convolution frame bound is invalid")) {
            try FFTConvolver(maximumLinearFrameCount: 2_097_153)
        }

        let convolver = try FFTConvolver(maximumLinearFrameCount: 8)
        #expect(throws: LoopRenderingError.invalidSound("FFT convolution input must not be empty")) {
            try convolver.convolve([], with: [1], outputFrameCount: 1, circular: false)
        }
        #expect(throws: LoopRenderingError.invalidSound("FFT convolution output frame count is out of bounds")) {
            try convolver.convolve([1], with: [1], outputFrameCount: 0, circular: false)
        }
        #expect(throws: LoopRenderingError.invalidSound("FFT convolution input must be finite")) {
            try convolver.convolve([.infinity], with: [1], outputFrameCount: 1, circular: false)
        }
        #expect(throws: LoopRenderingError.invalidSound("FFT convolution transform length is out of bounds")) {
            try convolver.convolve([1, 2, 3, 4, 5, 6], with: [1, 2, 3, 4], outputFrameCount: 8, circular: false)
        }
    }

    private func naiveConvolution(_ input: [Float], _ impulse: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: input.count + impulse.count - 1)
        for inputIndex in input.indices {
            for impulseIndex in impulse.indices {
                result[inputIndex + impulseIndex] += input[inputIndex] * impulse[impulseIndex]
            }
        }
        return result
    }
}
