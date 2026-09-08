import AVFoundation

/// Owns a private offline graph for one pitch-preserving sample transformation.
internal enum NativeSampleTimeStretcher {
    enum Failure: Error, Equatable {
        case invalidRange
        case invalidTarget
        case unsupportedRate(Double)
        case allocation
        case invalidLatency
        case setup(String)
        case renderStatus(Int)
        case truncatedOutput
    }

    static func render(_ sample: LoadedSample, frames: Range<Int>, targetFrames: Int,
                       maximumChannelFrames: Int) throws -> LoadedSample {
        guard !frames.isEmpty, frames.lowerBound >= 0, frames.upperBound <= sample.frameCount else {
            throw Failure.invalidRange
        }
        guard targetFrames > 0, targetFrames <= maximumChannelFrames / sample.channelCount,
              frames.count <= Int(UInt32.max) else { throw Failure.invalidTarget }
        let rate = Double(frames.count) / Double(targetFrames)
        guard (1.0 / 32...32).contains(rate) else { throw Failure.unsupportedRate(rate) }
        if frames.count == targetFrames, frames == 0..<sample.frameCount { return sample }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sample.sampleRate,
                                        channels: AVAudioChannelCount(sample.channelCount)),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames.count)),
              let inputChannels = input.floatChannelData,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let outputChannels = output.floatChannelData else { throw Failure.allocation }
        // Native planar buffer ownership requires this single interleaved-to-planar copy.
        input.frameLength = input.frameCapacity
        for channel in 0..<sample.channelCount {
            for frame in 0..<frames.count {
                inputChannels[channel][frame] = sample.samples[(frames.lowerBound + frame) * sample.channelCount + channel]
            }
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let stretch = AVAudioUnitTimePitch()
        stretch.rate = Float(rate)
        stretch.pitch = 0
        engine.attach(player)
        engine.attach(stretch)
        engine.connect(player, to: stretch, format: format)
        engine.connect(stretch, to: engine.mainMixerNode, format: format)
        defer { player.stop(); engine.stop() }
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            player.scheduleBuffer(input)
            try engine.start()
            player.play()
        } catch { throw Failure.setup(String(describing: error)) }
        let latency = stretch.auAudioUnit.latency * sample.sampleRate
        guard latency.isFinite, latency >= 0, latency <= sample.sampleRate else { throw Failure.invalidLatency }
        let prefix = Int(latency.rounded(.up))
        guard targetFrames <= Int.max - prefix else { throw Failure.invalidTarget }
        let total = targetFrames + prefix
        var samples = [Float](repeating: 0, count: targetFrames * sample.channelCount)
        var rendered = 0
        while rendered < total {
            try Task.checkCancellation()
            let count = min(4096, total - rendered)
            let status: AVAudioEngineManualRenderingStatus
            do { status = try engine.renderOffline(AVAudioFrameCount(count), to: output) }
            catch { throw Failure.setup(String(describing: error)) }
            guard status == .success else { throw Failure.renderStatus(status.rawValue) }
            guard output.frameLength == count else { throw Failure.truncatedOutput }
            for frame in min(count, max(0, prefix - rendered))..<count {
                for channel in 0..<sample.channelCount {
                    samples[(rendered + frame - prefix) * sample.channelCount + channel] = outputChannels[channel][frame]
                }
            }
            rendered += count
        }
        return try LoadedSample(samples: samples, channelCount: sample.channelCount, sampleRate: sample.sampleRate)
    }
}
