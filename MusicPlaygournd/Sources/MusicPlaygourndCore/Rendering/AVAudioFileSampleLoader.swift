import AVFoundation
import Foundation

public struct AVAudioFileSampleLoader: SampleLoading {
    public init() {}

    public func load(_ request: SampleLoadRequest) throws -> LoadedSample {
        let url = request.fileURL
        guard url.isFileURL, url.path.hasPrefix("/") else { throw SampleLoadingError.invalidFileURL(url) }
        guard request.sampleRate == PreparedLoop.requiredSampleRate else {
            throw SampleLoadingError.invalidSampleRate(request.sampleRate)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw SampleLoadingError.unreadableFile(url)
        }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw SampleLoadingError.unsupportedFormat(url) }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard (1...2).contains(channels) else { throw SampleLoadingError.unsupportedChannelCount(channels) }
        guard format.sampleRate.isFinite, format.sampleRate > 0 else {
            throw SampleLoadingError.invalidSampleRate(format.sampleRate)
        }
        guard file.length > 0 else { throw SampleLoadingError.invalidFrameCount(file.length) }
        let start = Int64((Double(file.length) * (request.region?.startFraction ?? 0)).rounded(.down))
        let endFraction = request.region?.endFraction ?? 1
        let end = endFraction == 1 ? file.length : Int64((Double(file.length) * endFraction).rounded(.down))
        guard end > start else { throw SampleLoadingError.invalidFrameCount(end - start) }
        let estimated = (Double(end - start) / format.sampleRate * request.sampleRate).rounded(.up)
        guard estimated.isFinite, estimated > 0, estimated <= Double(UInt32.max),
              request.maximumChannelFrames > 0,
              estimated <= Double(request.maximumChannelFrames / channels) else {
            throw LoopRenderingError.sampleCacheLimitExceeded(limit: request.maximumChannelFrames)
        }
        let capacity = AVAudioFrameCount(estimated)
        guard let target = AVAudioFormat(standardFormatWithSampleRate: request.sampleRate, channels: format.channelCount),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(end - start, 4_096))) else {
            throw SampleLoadingError.unsupportedFormat(url)
        }
        file.framePosition = start
        if format.sampleRate == request.sampleRate {
            guard let destination = output.floatChannelData, let source = input.floatChannelData else {
                throw SampleLoadingError.unsupportedFormat(url)
            }
            var written: AVAudioFrameCount = 0
            while written < capacity {
                let count = min(input.frameCapacity, capacity - written)
                do { try file.read(into: input, frameCount: count) }
                catch { throw SampleLoadingError.unreadableFile(url) }
                guard input.frameLength > 0 else {
                    throw SampleLoadingError.truncatedOutput(expected: Int(capacity), actual: Int(written))
                }
                // AVAudioFile may return a partial read. Borrow both buffers only for this copy.
                for channel in 0..<channels {
                    destination[channel].advanced(by: Int(written)).update(from: source[channel], count: Int(input.frameLength))
                }
                written += input.frameLength
            }
            output.frameLength = written
        } else {
            guard let converter = AVAudioConverter(from: format, to: target) else {
                throw SampleLoadingError.conversionFailed(url)
            }
            converter.primeMethod = .normal
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            var readError: SampleLoadingError?
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, state in
                let remaining = end - file.framePosition
                guard remaining > 0 else { state.pointee = .endOfStream; return nil }
                let count = min(input.frameCapacity, requested, AVAudioFrameCount(min(remaining, Int64(UInt32.max))))
                do {
                    try file.read(into: input, frameCount: count)
                    guard input.frameLength > 0 else {
                        readError = .truncatedOutput(expected: Int(count), actual: Int(input.frameLength))
                        state.pointee = .endOfStream
                        return nil
                    }
                    state.pointee = .haveData
                    return input
                } catch {
                    readError = .unreadableFile(url)
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            guard conversionError == nil, status != .error, status != .inputRanDry else {
                throw SampleLoadingError.conversionFailed(url)
            }
        }
        guard output.frameLength == capacity else {
            throw SampleLoadingError.truncatedOutput(expected: Int(capacity), actual: Int(output.frameLength))
        }
        guard let channelData = output.floatChannelData else { throw SampleLoadingError.unsupportedFormat(url) }
        // The native buffers are borrowed only here; the returned Array owns the decoded PCM.
        var samples = [Float](repeating: 0, count: Int(output.frameLength) * channels)
        for frame in 0..<Int(output.frameLength) {
            for channel in 0..<channels { samples[frame * channels + channel] = channelData[channel][frame] }
        }
        return try LoadedSample(samples: samples, channelCount: channels, sampleRate: request.sampleRate)
    }
}
