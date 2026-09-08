import Foundation
import SwiftMusic

/// Owns selected decoded assets for one render; event values share immutable PCM storage.
internal struct SamplePreparation: Sendable {
    static let maximumChannelFrames = Int(PreparedLoop.requiredSampleRate * PreparedLoop.maximumDurationSeconds)
        * PreparedLoop.maximumRows
    private struct StretchKey: Hashable {
        let asset: SampleLoadRequest.Key
        let frames: Range<Int>
        let targetFrames: Int
    }
    let voices: [Int: PreparedSampleVoice]

    init(sound: CompiledSound, loader: any SampleLoading, secondsPerBeat: Double = 0.5) throws {
        var cache: [SampleLoadRequest.Key: LoadedSample] = [:]
        var voices: [Int: PreparedSampleVoice] = [:]
        var processed: [StretchKey: LoadedSample] = [:]
        var processingRemaining = Self.maximumChannelFrames
        var remaining = Self.maximumChannelFrames
        for (index, event) in sound.events.enumerated() {
            guard sound.sources.indices.contains(event.sourceID), sound.sources[event.sourceID].id == event.sourceID else {
                throw LoopRenderingError.invalidSound("invalid sample source identity")
            }
            let source = sound.sources[event.sourceID]
            let url: URL
            let root: Pitch
            switch source.kind {
            case .fileSample(let fileURL, let rootPitch):
                guard event.sampleKey == nil else { throw LoopRenderingError.invalidSound("direct file has a bank key") }
                url = fileURL; root = rootPitch
            case .sampleBank(let bank):
                guard let key = event.sampleKey, let asset = bank.assets.first(where: { $0.key == key }) else {
                    throw LoopRenderingError.invalidSound("bank event has an unknown sample key")
                }
                url = asset.fileURL; root = asset.rootPitch
            default: continue
            }
            let request = SampleLoadRequest(fileURL: url, region: source.sampleRegion,
                                            maximumChannelFrames: remaining)
            let sample: LoadedSample
            if let cached = cache[request.key] {
                sample = cached
            } else {
                guard cache.count < PreparedLoop.maximumRows else {
                    throw LoopRenderingError.sampleCacheLimitExceeded(limit: PreparedLoop.maximumRows)
                }
                sample = try loader.load(request)
                guard sample.sampleRate == request.sampleRate else {
                    throw SampleLoadingError.invalidSampleRate(sample.sampleRate)
                }
                guard sample.samples.count <= remaining else {
                    throw LoopRenderingError.sampleCacheLimitExceeded(limit: Self.maximumChannelFrames)
                }
                remaining -= sample.samples.count
                cache[request.key] = sample
            }
            let slice = event.sampleSlice
            let lower = slice.map { sample.frameCount * $0.index / $0.count } ?? 0
            let upper = slice.map { sample.frameCount * ($0.index + 1) / $0.count } ?? sample.frameCount
            guard lower < upper else { throw NativeSampleTimeStretcher.Failure.invalidRange }
            let range = lower..<upper
            if let duration = source.sampleStretchDuration {
                let target = Double(duration.numerator) / Double(duration.denominator)
                    * secondsPerBeat * sample.sampleRate
                guard target.isFinite, target >= 1,
                      target <= Double(Self.maximumChannelFrames / sample.channelCount) else {
                    throw NativeSampleTimeStretcher.Failure.invalidTarget
                }
                let frames = Int(target.rounded(.up))
                let key = StretchKey(asset: request.key, frames: range, targetFrames: frames)
                let stretched: LoadedSample
                if let cached = processed[key] { stretched = cached }
                else {
                    guard processed.count < PreparedLoop.maximumRows else {
                        throw LoopRenderingError.sampleCacheLimitExceeded(limit: PreparedLoop.maximumRows)
                    }
                    stretched = try NativeSampleTimeStretcher.render(sample, frames: range,
                        targetFrames: frames, maximumChannelFrames: processingRemaining)
                    processingRemaining -= stretched.samples.count
                    processed[key] = stretched
                }
                voices[index] = PreparedSampleVoice(sample: stretched, rootPitch: root)
            } else {
                voices[index] = PreparedSampleVoice(sample: sample, rootPitch: root, frameRange: range)
            }
        }
        self.voices = voices
    }
}
