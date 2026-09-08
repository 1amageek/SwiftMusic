import Accelerate
import Foundation
import Testing
import SwiftMusic
import Synchronization
@testable import MusicPlaygourndCore

extension NativeHostTests {
    @Suite struct NativeSampleStretchTests {
        @Test(.timeLimit(.minutes(1)))
        func stretchPreservesFrequencyAndChangesDuration() throws {
            let rate = 44_100.0
            let input = try LoadedSample(samples: (0..<44_100).map {
                Float(sin(2 * Double.pi * 440 * Double($0) / rate))
            }, channelCount: 1, sampleRate: rate)
            for frames in [22_050, 88_200] {
                let output = try NativeSampleTimeStretcher.render(input, frames: 0..<input.frameCount,
                    targetFrames: frames, maximumChannelFrames: 100_000)
                #expect(output.frameCount == frames)
                // Measure steady-state frequency independently from duration and descriptor metadata.
                let range = (frames / 4)..<(frames * 3 / 4)
                var crossings = 0
                var energy = 0.0
                for index in range {
                    if output.samples[index] <= 0, output.samples[index + 1] > 0 { crossings += 1 }
                    energy += Double(output.samples[index] * output.samples[index])
                }
                let frequency = Double(crossings) * rate / Double(range.count)
                #expect(abs(frequency - 440) < 5)
                #expect(energy / Double(range.count) > 0.1)
                let size = 16_384
                let setup = try #require(vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD))
                defer { vDSP_DFT_DestroySetup(setup) }
                let start = (frames - size) / 2
                let signal = (0..<size).map { index in
                    output.samples[start + index] * Float(0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(size)))
                }
                let imaginary = [Float](repeating: 0, count: size)
                var real = imaginary
                var imag = imaginary
                vDSP_DFT_Execute(setup, signal, imaginary, &real, &imag)
                let peak = try #require((1..<(size / 2)).max {
                    real[$0] * real[$0] + imag[$0] * imag[$0] < real[$1] * real[$1] + imag[$1] * imag[$1]
                })
                #expect(abs(Double(peak) * rate / Double(size) - 440) < 3)
            }
            let identical = try NativeSampleTimeStretcher.render(input, frames: 0..<input.frameCount,
                targetFrames: input.frameCount, maximumChannelFrames: 100_000)
            let same = identical.samples == input.samples
            #expect(same)
            #expect(throws: NativeSampleTimeStretcher.Failure.invalidTarget) {
                try NativeSampleTimeStretcher.render(input, frames: 0..<input.frameCount,
                    targetFrames: 100_001, maximumChannelFrames: 100_000)
            }
            #expect(throws: NativeSampleTimeStretcher.Failure.unsupportedRate(44_100)) {
                try NativeSampleTimeStretcher.render(input, frames: 0..<input.frameCount,
                    targetFrames: 1, maximumChannelFrames: 100_000)
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func retainedStretchPreparationSurvivesLiveOverrides() throws {
            let loader = CountingLoader()
            let sound = try SoundCompiler().compile(Sample(file: URL(fileURLWithPath: "/stretch-fixture.wav"))
                .sampleStretch(to: .half).granular(.standard))
            let session = try LoopRenderSession(sound: sound, bpm: 120, beatsPerBar: 4,
                revision: 10, sampleLoader: loader)
            let address = try #require(session.catalog.descriptors.first {
                $0.address.target == .source(0) && $0.address.parameter == .pitchOffsetSemitones
            }?.address)
            let changed = try session.render(overrides: [.init(address: address, value: .number(12))])
            let differs = changed.samples != session.baseline.samples
            #expect(differs)
            #expect(loader.count.withLock { $0 } == 1)
            let restored = try session.render()
            let identical = restored.samples == session.baseline.samples
            #expect(identical)
        }

        private final class CountingLoader: SampleLoading {
            let count = Mutex(0)
            func load(_ request: SampleLoadRequest) throws -> LoadedSample {
                count.withLock { $0 += 1 }
                return try LoadedSample(samples: (0..<22_050).map {
                    Float(sin(2 * Double.pi * 440 * Double($0) / 44_100))
                }, channelCount: 1, sampleRate: 44_100)
            }
        }
    }
}
