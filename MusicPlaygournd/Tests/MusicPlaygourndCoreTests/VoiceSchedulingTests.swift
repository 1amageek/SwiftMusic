import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct VoiceSchedulingTests {
    private struct Loader: SampleLoading {
        func load(_ request: SampleLoadRequest) throws -> LoadedSample {
            let level: Float = request.fileURL.lastPathComponent == "a" ? 1
                : request.fileURL.lastPathComponent == "b" ? 0.25 : 0.5
            return try LoadedSample(samples: [Float](repeating: level, count: 44_100),
                                    channelCount: 1, sampleRate: 44_100)
        }
    }
    private struct Pair: Sound {
        let first: ModifiedSound
        let second: ModifiedSound
        var body: some Sound { first; second }
    }
    private var envelope: Envelope {
        get throws { try Envelope(attack: .zero, decay: .zero, sustainLevel: 1, release: .zero) }
    }
    private var bank: SampleBank {
        get throws {
            try SampleBank(["a", "b", "c"].map {
                try SampleAsset(key: $0, fileURL: URL(fileURLWithPath: "/virtual/\($0)"))
            })
        }
    }
    private func render<S: Sound>(_ sound: S, live: Bool = false) throws -> PreparedLoop {
        let compiler = SoundCompiler()
        let compiled = try live ? compiler.compile(sound, liveLoop: LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole))
            : compiler.compile(sound)
        return try LoopRenderer(sampleLoader: Loader()).render(compiled, bpm: 120, beatsPerBar: 4)
    }

    @Test(.timeLimit(.minutes(3)))
    func monoOldestAndQuietestUseActualVoicePCMAndKeepEvents() throws {
        let sound = try Sample(bank: bank).rhythm("x x x", cycle: .quarter)
            .sampleSelection("a b c", cycle: .quarter).gate(4).envelope(envelope)
        let plain = try render(sound)
        let mono = try render(sound.voicePolicy(.monophonic))
        let oldest = try render(sound.voicePolicy(.polyphonic(limit: 2, stealing: .oldest)))
        let quietest = try render(sound.voicePolicy(.polyphonic(limit: 2, stealing: .quietest)))
        let level = Float(80.0 / 127 * 0.35)
        let frame = 15_000
        #expect(abs(plain.samples[frame * 2] - 1.75 * level) < 1e-6)
        #expect(abs(mono.samples[frame * 2] - 0.5 * level) < 1e-6)
        #expect(abs(oldest.samples[frame * 2] - 0.75 * level) < 1e-6)
        #expect(abs(quietest.samples[frame * 2] - 1.5 * level) < 1e-6)
        #expect(mono.events == plain.events)
        #expect(oldest.events == plain.events)
        #expect(quietest.events == plain.events)
        let tied = try render(Sample(bank: bank).rhythm("x x x", cycle: .quarter)
            .sampleSelection("a a c", cycle: .quarter).gate(4).envelope(envelope)
            .voicePolicy(.polyphonic(limit: 2, stealing: .quietest)))
        #expect(abs(tied.samples[33_000 * 2] - 1.5 * level) < 1e-6)
        for offset in 0..<128 {
            let expected = (Float(127 - offset) / 127 + 0.25) * level
            #expect(abs(mono.samples[(7_350 + offset) * 2] - expected) < 1e-6)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func crossSourceChokeTerminatesAnActiveRelease() throws {
        let release = try Envelope(attack: .zero, decay: .zero, sustainLevel: 1, release: .seconds(1))
        let first = try Sample(file: URL(fileURLWithPath: "/virtual/a"))
            .rhythm("x", cycle: .quarter).gate(0.25).envelope(release).chokeGroup("hats")
        let second = try Sample(file: URL(fileURLWithPath: "/virtual/b"))
            .rhythm("x", cycle: .quarter).offset(.quarter).envelope(envelope).chokeGroup("hats")
        let result = try render(Pair(first: first, second: second))
        let level = Float(80.0 / 127 * 0.35)
        #expect(result.samples[20_000 * 2] > 0)
        #expect(abs(result.samples[23_000 * 2] - 0.25 * level) < 1e-6)
        #expect(result.events.count == 2)
    }

    @Test(.timeLimit(.minutes(3)))
    func sameFrameChokeUsesCompiledOrderAndShortRampEndsAtZero() throws {
        let first = try Sample(file: URL(fileURLWithPath: "/virtual/a"))
            .rhythm("x", cycle: .quarter).envelope(envelope).chokeGroup("same")
        let second = try Sample(file: URL(fileURLWithPath: "/virtual/b"))
            .rhythm("x", cycle: .quarter).envelope(envelope).chokeGroup("same")
        let result = try render(Pair(first: first, second: second))
        let level = Float(80.0 / 127 * 0.35)
        #expect(abs(result.samples[0] - 1.25 * level) < 1e-6)
        #expect(abs(result.samples[127 * 2] - 0.25 * level) < 1e-6)
        #expect(abs(result.samples[128 * 2] - 0.25 * level) < 1e-6)
    }

    @Test(.timeLimit(.minutes(3)))
    func seamlessVoiceStateRepeatsWithoutResettingAtZero() throws {
        let sound = try Sample(bank: bank).rhythm("x x", cycle: .whole)
            .sampleSelection("a b").offset(try MusicalTime(numerator: 3, denominator: 1))
            .gate(2).envelope(envelope).voicePolicy(.monophonic)
        let loop = try render(sound, live: true)
        #expect(loop.samples.contains { $0 > 0 })
        #expect(loop.events.contains { $0.wrapsLoopBoundary })
        #expect(loop.samples[0] > 0)
    }
    @Test(.timeLimit(.minutes(3)))
    func circularPCMEqualsContinuousFinitePlaybackThroughSteals() throws {
        let sound = try Synthesizer(.sine).rhythm("x x", cycle: .whole)
            .offset(.quarter).gate(1.5).envelope(envelope).voicePolicy(.monophonic)
        let loop = try render(sound, live: true)
        let reference = try render(Synthesizer(.sine)
            .rhythm("x*6", cycle: MusicalTime(numerator: 12, denominator: 1))
            .offset(.quarter).gate(1.5).envelope(envelope).voicePolicy(.monophonic))
        let frames = loop.samples.count / 2
        var error: Float = 0
        for index in loop.samples.indices {
            error = max(error, abs(loop.samples[index] - reference.samples[frames * 2 + index]))
        }
        #expect(error == 0)
    }

    @Test(.timeLimit(.minutes(3)))
    func historyDependentQuietestAllocationRejectsANonperiodicBoundary() throws {
        let starts = [0, 1, 9, 11, 19]
        let durations = [17, 20, 1, 11, 18]
        let levels: [[Float]] = [
            [3,1,1,1,4,1,0,0,2,2,1,2,0,0,4,4,4,1,1,4],
            [2,1,0,0,2,3,1,1,1,3,1,2,3,4,4,3,0,4,3,1],
            [2,3,2,2,4,1,4,0,0,3,1,3,1,0,0,1,2,0,3,0],
            [2,4,3,0,3,4,2,3,4,4,3,3,1,2,3,1,2,3,1,2],
            [3,3,2,4,1,4,1,3,3,1,0,3,1,2,1,1,3,2,3,3]
        ]
        let compiled = try SoundCompiler().compile(Sample(file: URL(fileURLWithPath: "/virtual/a"))
            .voicePolicy(.polyphonic(limit: 2, stealing: .quietest)))
        let event = try #require(compiled.events.first)
        let source = try #require(compiled.sources.first)
        let contour = try VoiceEnvelope(envelope, noteDuration: 1, gate: 1)
        let templates = try starts.indices.map { index in
            let pcm = try LoadedSample(samples: Array(levels[index].prefix(durations[index])),
                                       channelCount: 1, sampleRate: 44_100)
            return try RenderedVoice(event: event, source: source, eventIndex: index,
                startFrame: starts[index], eventFrames: durations[index], secondsPerBeat: 0.5,
                sampleVoice: PreparedSampleVoice(sample: pcm, rootPitch: .middleC),
                amplitudeEnvelope: contour, amplitude: 1, leftGain: 1, rightGain: 1, edgeFrames: 1)
        }
        #expect(throws: LoopRenderingError.nonPeriodicVoiceAllocation) {
            try VoiceScheduler.render(templates: templates, sourceCount: 1, frameCount: 20, seamless: true)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func oneFrameRemainingChokeEndsImmediatelyAtTheAssetBoundary() throws {
        struct ShortLoader: SampleLoading {
            func load(_ request: SampleLoadRequest) throws -> LoadedSample {
                try LoadedSample(samples: [1, 1], channelCount: 1, sampleRate: 44_100)
            }
        }
        let first = try Sample(file: URL(fileURLWithPath: "/virtual/a"))
            .envelope(envelope).chokeGroup("short")
        let second = try Sample(file: URL(fileURLWithPath: "/virtual/b"))
            .offset(MusicalTime(numerator: 1, denominator: 22_050))
            .envelope(envelope).chokeGroup("short")
        let compiled = try SoundCompiler().compile(Pair(first: first, second: second))
        let loop = try LoopRenderer(sampleLoader: ShortLoader()).render(compiled, bpm: 120, beatsPerBar: 4)
        let level = Float(80.0 / 127 * 0.35)
        #expect(abs(loop.samples[0] - level) < 1e-6)
        #expect(abs(loop.samples[2] - level) < 1e-6)
        #expect(abs(loop.samples[4] - level) < 1e-6)
        #expect(loop.samples.dropFirst(6).allSatisfy { $0 == 0 })
    }

}
