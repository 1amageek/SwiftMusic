import Foundation
import SwiftMusic

/// Owns selected decoded assets for one render; event values share immutable PCM storage.
internal struct SamplePreparation: Sendable {
    static let maximumChannelFrames = Int(PreparedLoop.requiredSampleRate * PreparedLoop.maximumDurationSeconds)
        * PreparedLoop.maximumRows
    let voices: [Int: PreparedSampleVoice]

    init(sound: CompiledSound, loader: any SampleLoading) throws {
        var cache: [SampleLoadRequest.Key: LoadedSample] = [:]
        var voices: [Int: PreparedSampleVoice] = [:]
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
            voices[index] = PreparedSampleVoice(sample: sample, rootPitch: root)
        }
        self.voices = voices
    }
}
