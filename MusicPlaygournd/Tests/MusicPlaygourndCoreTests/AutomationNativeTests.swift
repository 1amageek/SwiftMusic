import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
    struct AutomationNativeTests {
        @MainActor
        @Test(.timeLimit(.minutes(3)))
        func continuousAutomationReachesNativeChannelsAndInvalidCycleRetainsPlayback() throws {
            let steps = try StepAutomation(values: [0, 1], cycle: .whole)
            let lfo = try LFO(waveform: .sine, rate: .synchronized(period: .whole), phase: 0)
            let curve = try AutomationCurve(points: [
                AutomationPoint(position: .zero, value: 0, interpolationToNext: .linear),
                AutomationPoint(position: .half, value: 1, interpolationToNext: .linear)
            ], cycle: .whole)
            let gain = try GainAutomation(.steps(steps), from: 0.2, to: 0.8)
            let pan = try PanAutomation(.steps(steps), from: -1, to: 1)
            let pitch = try PitchAutomation(.lfo(lfo),
                from: Semitones(value: -2), to: Semitones(value: 2))
            let cutoff = try CutoffAutomation(.curve(curve),
                from: Frequency(hertz: 200), to: Frequency(hertz: 4_000))
            let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .beats(32))
            let compiler = SoundCompiler()
            let compiled = try compiler.compile(Synthesizer(.sine)
                .notes("C4 C4 C4 C4")
                .transpose(pitch)
                .lowPass(cutoff)
                .gain(gain)
                .pan(pan), liveLoop: policy)
            let renderer = LoopRenderer()
            let loop = try renderer.render(compiled, bpm: 120, beatsPerBar: 4)
            #expect(loop.beatCount == 4)
            #expect(loop.events.count == 4)
            let engine = try AudioLoopEngine()
            defer { engine.stop() }
            engine.beginUpdate(revision: 61)
            try engine.submit(loop: loop, revision: 61)
            try engine.prepareOfflineRenderingForTests()
            try engine.play()

            var early = (left: 0.0, right: 0.0)
            var late = (left: 0.0, right: 0.0)
            var frame = 0
            while frame < 81_920 {
                let pcm = try engine.renderOfflineForTests(frameCount: 4_096)
                try #require(pcm.count == 8_192)
                #expect(pcm.allSatisfy { $0.isFinite })
                for offset in 0..<4_096 {
                    let position = frame + offset
                    let left = Double(pcm[offset * 2])
                    let right = Double(pcm[offset * 2 + 1])
                    if (12_000..<30_000).contains(position) {
                        early.left += left * left
                        early.right += right * right
                    }
                    if (60_000..<78_000).contains(position) {
                        late.left += left * left
                        late.right += right * right
                    }
                }
                frame += 4_096
            }
            #expect(early.left > 0.01)
            #expect(early.right < early.left * 0.01)
            #expect(late.right > 0.01)
            #expect(late.left < late.right * 0.01)
            #expect(engine.outputMeter().interleavedSamples.contains { abs($0) > 0.0001 })

            let nonperiodic = try LFO(waveform: .sine,
                rate: .hertz(Frequency(hertz: 0.7)), phase: 0)
            let invalid = try compiler.compile(Synthesizer(.sine)
                .notes("C4 C4 C4 C4")
                .gain(GainAutomation(.lfo(nonperiodic), from: 0.2, to: 0.8)), liveLoop: policy)
            engine.beginUpdate(revision: 62)
            #expect(throws: LoopRenderingError.self) {
                try renderer.render(invalid, bpm: 120, beatsPerBar: 4)
            }
            #expect(engine.snapshot().revision == 61)
            #expect(engine.snapshot().isPlaying)
            #expect(try engine.renderOfflineForTests(frameCount: 4_096).contains { abs($0) > 0.0001 })
        }
    }
}
