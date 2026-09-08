import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
    struct SpatialPositionRenderingTests {
        @MainActor
        @Test(.timeLimit(.minutes(3)))
        func positionUsesDeclaredStereoDepthChainAndRetainsAudioOnInvalidCoordinates() async throws {
            let compiler = SoundCompiler()
            let renderer = LoopRenderer()
            let source = Synthesizer(.saw).notes("C6").gain(0.05)
            let near = try renderer.render(compiler.compile(source.position(.init(x: -1, depth: 0))),
                bpm: 120, beatsPerBar: 4)
            let nearReference = try renderer.render(compiler.compile(source.pan(-1)), bpm: 120, beatsPerBar: 4)
            let nearMatches = near.samples == nearReference.samples
            #expect(nearMatches)
            #expect(energy(near.samples, channel: 0) > 0.00001)
            #expect(energy(near.samples, channel: 1) < 0.0000001)

            let far = try renderer.render(compiler.compile(source.position(.init(x: 1, depth: 1))),
                bpm: 120, beatsPerBar: 4)
            let reference = source.pan(1)
                .gain(pow(10, -6.0 / 20))
                .effect(.filter(kind: .lowPass, cutoffHz: 4_000, resonance: 1 / sqrt(2)))
                .effect(.reverb(roomSize: 1, wet: 0.35))
            let farReference = try renderer.render(compiler.compile(reference), bpm: 120, beatsPerBar: 4)
            let farMatches = far.samples == farReference.samples
            #expect(farMatches)
            #expect(far.samples.count > near.samples.count)
            #expect(far.samples.dropFirst(near.samples.count).contains { abs($0) > 0.000001 })
            #expect(energy(far.samples, channel: 1) < energy(near.samples, channel: 0))

            let engine = try AudioLoopEngine()
            defer { engine.stop() }
            engine.beginUpdate(revision: 1)
            try engine.submit(loop: far, revision: 1)
            try engine.play()
            try await Task.sleep(for: .milliseconds(250))
            let output = engine.outputMeter()
            #expect(output.interleavedSamples.contains { abs($0) > 0.000001 })
            engine.beginUpdate(revision: 2)
            for position in [SpatialPosition(x: .nan, depth: 0), .init(x: 0, depth: -0.1), .init(x: 1.1, depth: 0)] {
                #expect(throws: SoundCompilationError.self) { try compiler.compile(source.position(position)) }
            }
            let retained = engine.snapshot()
            #expect(retained.revision == 1 && retained.isPlaying)
            let retainsFar = retained.loop == far
            #expect(retainsFar)
        }

        private func energy(_ samples: [Float], channel: Int) -> Double {
            var sum = 0.0
            for index in stride(from: channel, to: samples.count, by: 2) { sum += Double(samples[index]) * Double(samples[index]) }
            return sum / Double(max(1, samples.count / 2))
        }
    }
}
