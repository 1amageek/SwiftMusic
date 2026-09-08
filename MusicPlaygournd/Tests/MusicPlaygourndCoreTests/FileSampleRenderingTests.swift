import AVFoundation
import Foundation
import SwiftMusic
import Synchronization
import Testing
@testable import MusicPlaygourndCore

struct FileSampleRenderingTests {
    private struct SampleSourceGroup: Sound {
        let sounds: [ModifiedSound]

        var body: some Sound {
            for sound in sounds {
                sound
            }
        }
    }

    private struct FixtureLoader: SampleLoading {
        let sample: LoadedSample

        func load(_ request: SampleLoadRequest) throws -> LoadedSample {
            sample
        }
    }

    private final class RecordingFixtureLoader: SampleLoading {
        let sample: LoadedSample
        let requests = Mutex<[SampleLoadRequest]>([])

        init(sample: LoadedSample) {
            self.sample = sample
        }

        func load(_ request: SampleLoadRequest) throws -> LoadedSample {
            requests.withLock { $0.append(request) }
            return sample
        }
    }

    private final class CountingLoader: SampleLoading {
        let requests = Mutex<[SampleLoadRequest]>([])
        func load(_ request: SampleLoadRequest) throws -> LoadedSample {
            requests.withLock { $0.append(request) }
            return try AVAudioFileSampleLoader().load(request)
        }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "SwiftMusicSamples-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func remove(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record(error) }
    }

    private func write(_ url: URL, samples: [[Float]], rate: Double = 44_100) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: UInt32(samples.count), interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(samples[0].count)))
        buffer.frameLength = buffer.frameCapacity
        let channels = try #require(buffer.floatChannelData)
        for channel in samples.indices {
            for frame in samples[channel].indices { channels[channel][frame] = samples[channel][frame] }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
    }

    private var immediate: Envelope {
        get throws { try Envelope(attack: .zero, decay: .zero, sustainLevel: 1, release: .zero) }
    }

    private func render<S: Sound>(_ sound: S, loader: any SampleLoading = AVAudioFileSampleLoader()) throws -> PreparedLoop {
        try LoopRenderer(sampleLoader: loader).render(SoundCompiler().compile(sound), bpm: 120, beatsPerBar: 4)
    }

    @Test(.timeLimit(.minutes(3)))
    func realStereoFilePreservesFramesAndStopsAtAssetEnd() throws {
        let directory = try directory()
        defer { remove(directory) }
        let url = directory.appending(path: "stereo.wav")
        let left = (1...8).map { Float($0) / 16 }
        let right = Array(left.reversed())
        try write(url, samples: [left, right])
        let loop = try render(Sample(file: url).envelope(immediate))
        let level = Float(80.0 / 127 * 0.35)
        for frame in 0..<8 {
            #expect(abs(loop.samples[frame * 2] - left[frame] * level) < 1e-7)
            #expect(abs(loop.samples[frame * 2 + 1] - right[frame] * level) < 1e-7)
        }
        #expect(loop.samples.dropFirst(16).allSatisfy { $0 == 0 })
        #expect(abs(loop.events[0].durationBeats - 16.0 / 44_100) < 1e-12)
        let longRelease = try Envelope(attack: .zero, decay: .zero, sustainLevel: 1, release: .seconds(100))
        let exhausted = try render(Sample(file: url).envelope(longRelease))
        #expect(exhausted.beatCount == 4)
        #expect(exhausted.events[0].durationBeats == loop.events[0].durationBeats)
    }

    @Test(.timeLimit(.minutes(3)))
    func regionReverseRateAndRootedPitchTraverseKnownFrames() throws {
        let directory = try directory()
        defer { remove(directory) }
        let url = directory.appending(path: "ramp.wav")
        let values = (1...8).map { Float($0) / 16 }
        try write(url, samples: [values])
        let region = try SampleRegion(startFraction: 0.25, endFraction: 0.75)
        let cropped = try render(Sample(file: url).sampleRegion(region).sampleReversed()
            .samplePlaybackRate(2).envelope(immediate))
        let level = Float(80.0 / 127 * 0.35)
        #expect(abs(cropped.samples[0] - values[5] * level) < 1e-7)
        #expect(abs(cropped.samples[2] - values[3] * level) < 1e-7)
        #expect(cropped.samples.dropFirst(4).allSatisfy { $0 == 0 })
        let octave = try render(Sample(file: url).notes("C5").envelope(immediate))
        for frame in 0..<4 {
            #expect(abs(octave.samples[frame * 2] - values[frame * 2] * level) < 1e-7)
        }
        let fractional = try render(Sample(file: url).transpose(PitchPattern("0.5")).envelope(immediate))
        let position = pow(2, 0.5 / 12)
        let expected = Double(values[1]) + (Double(values[2]) - Double(values[1])) * (position - 1)
        #expect(abs(Double(fractional.samples[2]) - expected * Double(level)) < 1e-7)
    }

    @Test(.timeLimit(.minutes(3)))
    func bankSelectionUsesCompilerKeysAndCachesPCMIndependentlyOfRootPitch() throws {
        let directory = try directory()
        defer { remove(directory) }
        let url = directory.appending(path: "shared.wav")
        try write(url, samples: [[Float](repeating: 0.5, count: 8)])
        let bank = try SampleBank([
            SampleAsset(key: "a", fileURL: url),
            SampleAsset(key: "b", fileURL: url, rootPitch: Pitch(midiNote: 72))
        ])
        let sound = try Sample(bank: bank).rhythm("x", cycle: .quarter)
            .sampleSelection("<a b>", cycle: .quarter).envelope(immediate)
        let compiled = try SoundCompiler().compile(sound, liveLoop: LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole))
        #expect(compiled.events.map(\.sampleKey) == ["a", "b", "a", "b"])
        let loader = CountingLoader()
        let loop = try LoopRenderer(sampleLoader: loader).render(compiled, bpm: 120, beatsPerBar: 4)
        #expect(loader.requests.withLock { $0.count } == 1)
        let durations = loop.events.map { ($0.durationBeats * 44_100 / 2).rounded() }
        #expect(durations == [8, 16, 8, 16])
        #expect(loader.requests.withLock { $0[0].maximumChannelFrames } == SamplePreparation.maximumChannelFrames)
    }

    @Test(.timeLimit(.minutes(3)))
    func nativeConversionAndInputFailuresRemainExplicit() throws {
        let directory = try directory()
        defer { remove(directory) }
        let url = directory.appending(path: "resample.wav")
        let values = (0..<4_800).map { Float(sin(2 * Double.pi * 480 * Double($0) / 48_000)) }
        try write(url, samples: [values], rate: 48_000)
        let loader = AVAudioFileSampleLoader()
        let loaded = try loader.load(SampleLoadRequest(fileURL: url, maximumChannelFrames: 10_000))
        #expect(loaded.frameCount == 4_410)
        #expect(loaded.sampleRate == 44_100)
        var crossings = 0
        for index in 1..<loaded.samples.count {
            if loaded.samples[index - 1] <= 0, loaded.samples[index] > 0 { crossings += 1 }
        }
        // Check interior phase as well as frequency so converter latency cannot pass.
        for index in 100..<4_300 {
            let expected = sin(2 * Double.pi * 480 * Double(index) / 44_100)
            #expect(abs(Double(loaded.samples[index]) - expected) < 0.002)
        }
        #expect(abs(Double(crossings) / 0.1 - 480) <= 20)
        #expect(throws: LoopRenderingError.sampleCacheLimitExceeded(limit: 1)) {
            try loader.load(SampleLoadRequest(fileURL: url, maximumChannelFrames: 1))
        }
        let missing = directory.appending(path: "missing.wav")
        #expect(throws: SampleLoadingError.unreadableFile(missing)) {
            try render(Sample(file: missing))
        }
        let malformed = directory.appending(path: "bad.wav")
        try Data([1, 2, 3]).write(to: malformed)
        #expect(throws: SampleLoadingError.unsupportedFormat(malformed)) {
            try loader.load(SampleLoadRequest(fileURL: malformed, maximumChannelFrames: 100))
        }
        let multichannel = directory.appending(path: "three.wav")
        // IEEE Float WAV with three interleaved channels exercises native format admission.
        var wave = Data("RIFF".utf8)
        func append32(_ value: UInt32) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { wave.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { wave.append(contentsOf: $0) }
        }
        append32(48)
        wave.append(contentsOf: "WAVEfmt ".utf8)
        append32(16)
        append16(3)
        append16(3)
        append32(44_100)
        append32(529_200)
        append16(12)
        append16(32)
        wave.append(contentsOf: "data".utf8)
        append32(12)
        for _ in 0..<3 { append32(Float(1).bitPattern) }
        try wave.write(to: multichannel)
        #expect(throws: SampleLoadingError.unsupportedChannelCount(3)) {
            try loader.load(SampleLoadRequest(fileURL: multichannel, maximumChannelFrames: 100))
        }
        let nonfinite = directory.appending(path: "nan.wav")
        try write(nonfinite, samples: [[.nan]])
        #expect(throws: SampleLoadingError.nonFinitePCM(index: 0)) {
            try loader.load(SampleLoadRequest(fileURL: nonfinite, maximumChannelFrames: 100))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func rootedSampleTuningAndPitchEnvelopeUseKnownTraversalIncrements() throws {
        let url = URL(fileURLWithPath: "/virtual/ramp.wav")
        let fixture = try LoadedSample(
            samples: (0..<64).map { Float($0) / 64 },
            channelCount: 1,
            sampleRate: PreparedLoop.requiredSampleRate
        )
        let loader = FixtureLoader(sample: fixture)
        let immediate = try immediate
        let level = Float(80.0 / 127 * 0.35)

        let plain = try render(
            Sample(file: url).notes("C4").envelope(immediate),
            loader: loader
        )
        let tuning = try Tuning(referencePitch: .middleC, frequencyHz: 523.2511306011972)
        let tuned = try render(
            Sample(file: url).tuning(tuning).notes("C4").envelope(immediate),
            loader: loader
        )
        let pitchSweep = try Envelope(
            attack: .milliseconds(1),
            decay: .zero,
            sustainLevel: 1,
            release: .zero
        )
        let pitchEnvelope = try render(
            Sample(file: url)
                .pitchEnvelope(pitchSweep, depth: try Semitones(value: 12))
                .notes("C4")
                .envelope(immediate),
            loader: loader
        )

        for frame in 0..<8 {
            let plainValue = fixture.samples[frame] * level
            let doubledValue = fixture.samples[frame * 2] * level
            #expect(abs(plain.samples[frame * 2] - plainValue) < 1e-6)
            #expect(abs(tuned.samples[frame * 2] - doubledValue) < 1e-6)

            let contour = min(1, Double(frame) / (0.001 * PreparedLoop.requiredSampleRate))
            let position = (0..<frame).reduce(0.0) { position, previousFrame in
                position + pow(2, min(1, Double(previousFrame) / (0.001 * PreparedLoop.requiredSampleRate)))
            }
            let first = min(Int(position.rounded(.down)), fixture.samples.count - 1)
            let second = min(first + 1, fixture.samples.count - 1)
            let fraction = position - Double(first)
            let sweptValue = (Double(fixture.samples[first])
                + (Double(fixture.samples[second]) - Double(fixture.samples[first])) * fraction) * Double(level)
            #expect(contour.isFinite)
            #expect(abs(Double(pitchEnvelope.samples[frame * 2]) - sweptValue) < 1e-6)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func seamlessFileVoiceFoldsAtBoundaryAndReportsAssetDuration() throws {
        let url = URL(fileURLWithPath: "/virtual/one-second.wav")
        let fixture = try LoadedSample(
            samples: (0..<44_100).map { Float($0) / 44_100 },
            channelCount: 1,
            sampleRate: PreparedLoop.requiredSampleRate
        )
        let loader = FixtureLoader(sample: fixture)
        let immediate = try immediate
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)
        let crossing = try Sample(file: url)
            .rhythm("x", cycle: .whole)
            .offset(try MusicalTime(numerator: 3, denominator: 1))
            .envelope(immediate)
        let compiled = try SoundCompiler().compile(crossing, liveLoop: policy)
        let compiledEvent = try #require(compiled.events.first)
        let compiledStart = compiledEvent.start
        let expectedStart = try MusicalTime(numerator: 3, denominator: 1)
        #expect(compiled.events.count == 1)
        #expect(compiledStart == expectedStart)

        let loop = try LoopRenderer(sampleLoader: loader).render(compiled, bpm: 120, beatsPerBar: 4)
        let event = try #require(loop.events.first)
        #expect(loop.beatCount == 4)
        #expect(abs(event.startBeat - 3) < 1e-12)
        #expect(abs(event.durationBeats - 2) < 1e-12)
        #expect(event.wrapsLoopBoundary)
        #expect(event.isActive(at: 0.25, in: loop.beatCount))
        #expect(event.isActive(at: 3.25, in: loop.beatCount))
        #expect(!event.isActive(at: 2.0, in: loop.beatCount))

        let reference = try render(
            Sample(file: url).rhythm("x", cycle: .whole).envelope(immediate),
            loader: loader
        )
        let frameCount = Int(loop.beatCount * 60 / loop.bpm * loop.sampleRate)
        let startFrame = Int(3 * 60 / loop.bpm * loop.sampleRate)
        var maximumError: Float = 0
        for frame in 0..<frameCount {
            let sourceFrame = (frame - startFrame + frameCount) % frameCount
            let expected = sourceFrame < fixture.frameCount
                ? reference.samples[sourceFrame * 2]
                : 0
            maximumError = max(maximumError, abs(loop.samples[frame * 2] - expected))
        }
        #expect(maximumError < 1e-6)
    }

    @Test(.timeLimit(.minutes(3)))
    func injectedLoaderRejectsWrongSampleRateBeforeRendering() throws {
        let url = URL(fileURLWithPath: "/virtual/wrong-rate.wav")
        let invalid = try LoadedSample(samples: [0], channelCount: 1, sampleRate: 48_000)
        #expect(throws: SampleLoadingError.invalidSampleRate(48_000)) {
            try render(Sample(file: url), loader: FixtureLoader(sample: invalid))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func distinctSampleCacheUsesAllRowsAndDecrementsRemainingBudget() throws {
        let urls = (0..<PreparedLoop.maximumRows).map {
            URL(fileURLWithPath: "/virtual/cache-\($0).wav")
        }
        let immediate = try immediate
        let sounds = try urls.map {
            try Sample(file: $0).envelope(immediate)
        }
        let sound = SampleSourceGroup(sounds: sounds)
        let fixture = try LoadedSample(
            samples: [0],
            channelCount: 1,
            sampleRate: PreparedLoop.requiredSampleRate
        )
        let loader = RecordingFixtureLoader(sample: fixture)
        _ = try LoopRenderer(sampleLoader: loader).render(
            SoundCompiler().compile(sound),
            bpm: 120,
            beatsPerBar: 4
        )

        let requests = loader.requests.withLock { $0 }
        #expect(requests.count == PreparedLoop.maximumRows)
        #expect(Set(requests.map(\.fileURL)).count == PreparedLoop.maximumRows)
        #expect(requests.first?.maximumChannelFrames == SamplePreparation.maximumChannelFrames)
        #expect(requests.last?.maximumChannelFrames == SamplePreparation.maximumChannelFrames - PreparedLoop.maximumRows + 1)
    }
    @Test(.timeLimit(.minutes(3)))
    func sampleCacheRejectsDistinctAndAggregateOverflow() throws {
        let assets = try (0...PreparedLoop.maximumRows).map {
            try SampleAsset(key: "s\($0)", fileURL: URL(fileURLWithPath: "/virtual/overflow-\($0).wav"))
        }
        let bank = try SampleBank(assets)
        let pattern = try SampleSelectionPattern(assets.map(\.key).joined(separator: " "))
        let many = try SoundCompiler().compile(Sample(bank: bank).rhythm("x*33").sampleSelection(pattern))
        let single = try LoadedSample(samples: [0], channelCount: 1, sampleRate: 44_100)
        #expect(throws: LoopRenderingError.sampleCacheLimitExceeded(limit: PreparedLoop.maximumRows)) {
            try SamplePreparation(sound: many, loader: FixtureLoader(sample: single))
        }
        let pair = try SoundCompiler().compile(Sample(bank: bank).rhythm("x x").sampleSelection("s0 s1"))
        let large = try LoadedSample(samples: [Float](repeating: 0,
            count: SamplePreparation.maximumChannelFrames / 2 + 1), channelCount: 1, sampleRate: 44_100)
        #expect(throws: LoopRenderingError.sampleCacheLimitExceeded(limit: SamplePreparation.maximumChannelFrames)) {
            try SamplePreparation(sound: pair, loader: FixtureLoader(sample: large))
        }
    }


    @Test(.timeLimit(.minutes(1)))
    func slicesAndChopsUseSelectedPCMWithoutReadingAdjacentSlices() throws {
        let directory = try directory()
        defer { remove(directory) }
        let url = directory.appending(path: "slices.wav")
        let values = (1...16).map { Float($0) / 32 }
        try write(url, samples: [values])
        let base = try Sample(file: url).envelope(immediate)
        let baseline = try render(base)
        let one = try render(base.chopped(into: 1))
        let identical = baseline.samples == one.samples
        #expect(identical)
        let selected = try render(base.sampleRegion(SampleRegion(startFraction: 0.25, endFraction: 0.75))
            .sampleSlice(SampleSlice(index: 1, count: 2)).sampleReversed().samplePlaybackRate(2))
        let level = Float(80.0 / 127 * 0.35)
        #expect(abs(selected.samples[0] - values[11] * level) < 1e-7)
        #expect(abs(selected.samples[2] - values[9] * level) < 1e-7)
        #expect(selected.samples.dropFirst(4).allSatisfy { $0 == 0 })
        let chopped = try render(base.chopped(into: 4))
        #expect(chopped.events.count == 4)
        let nested = try render(base.chopped(into: 2).chopped(into: 2))
        let nestedMatchesDirect = nested.samples == chopped.samples
        #expect(nestedMatchesDirect)
        for (index, event) in chopped.events.enumerated() {
            let frame = Int((event.startBeat * 22_050).rounded(.down))
            #expect(abs(chopped.samples[frame * 2] - values[index * 4] * level) < 1e-7)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func granularNormalizesWindowsHasStableSeedsAndWrapsVoiceState() throws {
        let directory = try directory()
        defer { remove(directory) }
        let url = directory.appending(path: "grains.wav")
        try write(url, samples: [[Float](repeating: 0.5, count: 22_050)])
        let base = try Sample(file: url).envelope(immediate)
        let plain = try render(base)
        let grains = try render(base.granular(.standard))
        #expect(grains.samples[0] == 0)
        for index in stride(from: 2, to: 40_000, by: 199) {
            #expect(abs(grains.samples[index] - plain.samples[index]) < 1e-7)
        }
        let configuration = try GranularPlayback(grainDuration: .milliseconds(40), overlap: 0.5,
            positionJitter: 1, seed: 92)
        let a = try render(base.granular(configuration))
        let b = try render(base.granular(configuration))
        let stable = a.samples == b.samples
        #expect(stable)
        let different = try render(base.granular(GranularPlayback(grainDuration: .milliseconds(40),
            overlap: 0.5, positionJitter: 1, seed: 93)))
        let changed = a.samples != different.samples
        #expect(changed)
        let loop = try SoundCompiler().compile(base.rhythm("~ ~ ~ x").gate(2).samplePlaybackRate(0.5).granular(configuration),
            liveLoop: LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole))
        let wrapped = try LoopRenderer().render(loop, bpm: 120, beatsPerBar: 4)
        #expect(wrapped.samples.allSatisfy { $0.isFinite })
        #expect(wrapped.samples.prefix(20_000).contains { abs($0) > 0.01 })
        let excessive = try GranularPlayback(grainDuration: .milliseconds(40), overlap: 0.99999,
            positionJitter: 0, seed: 0)
        #expect(throws: LoopRenderingError.self) { try render(base.granular(excessive)) }
    }

    @Test(.timeLimit(.minutes(1)))
    func granularUsesOrdinaryRootTuningEnvelopeAndGlideTraversal() throws {
        let sample = try LoadedSample(samples: (0..<88_200).map {
            Float(sin(2 * Double.pi * 220 * Double($0) / 44_100))
        }, channelCount: 1, sampleRate: 44_100)
        let loader = FixtureLoader(sample: sample)
        let base = try Sample(file: URL(fileURLWithPath: "/granular-fixture.wav"), rootPitch: Pitch(midiNote: 57))
            .notes("A3 C4").envelope(immediate)
            .tuning(Tuning(referencePitch: Pitch(midiNote: 69), frequencyHz: 442))
            .pitchEnvelope(Envelope(attack: .milliseconds(100), decay: .zero, sustainLevel: 1, release: .zero),
                depth: Semitones(value: 2))
            .portamento(Portamento(duration: .seconds(.milliseconds(200))))
        let plain = try render(base, loader: loader)
        let granular = try render(base.granular(.standard), loader: loader)
        var maximumError: Float = 0
        for index in plain.samples.indices {
            maximumError = max(maximumError, abs(plain.samples[index] - granular.samples[index]))
        }
        #expect(maximumError < 1e-5)
        #expect(plain.events == granular.events)
    }

    @Test(.timeLimit(.minutes(1)))
    func granularChecksQuantizedHopAndLaunchBudgetBeforeAllocation() throws {
        let fractional = try GranularPlayback(grainDuration: .microseconds(250), overlap: 0,
            positionJitter: 0, seed: 0)
        let dimensions = try GranularSampleVoice.dimensions(fractional, eventFrames: 100)
        #expect(dimensions.frames == 12)
        #expect(dimensions.hop == 12)
        #expect(dimensions.slots == 1)
        #expect(throws: LoopRenderingError.self) {
            try GranularSampleVoice.dimensions(fractional, eventFrames: 12 * 4096 + 1)
        }
        let highOverlap = try GranularPlayback(grainDuration: .seconds(1), overlap: 0.9999,
            positionJitter: 0, seed: 0)
        #expect(throws: LoopRenderingError.self) {
            try GranularSampleVoice.dimensions(highOverlap, eventFrames: 100)
        }
    }
}
