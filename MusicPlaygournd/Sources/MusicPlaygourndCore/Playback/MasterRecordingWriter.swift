import AVFoundation
import Foundation

/// Owns file I/O and conversion away from the native audio callback.
internal actor MasterRecordingWriter {
    private let didPublish: (@Sendable () async -> Void)?
    private let request: MasterRecordingRequest
    private let capture: MasterRecordingCapture
    private let temporary: URL
    private let converter: AVAudioConverter
    private let captured: AVAudioPCMBuffer
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var file: AVAudioFile?
    private var written: Int64 = 0

    init(request: MasterRecordingRequest, capture: MasterRecordingCapture, format: AVAudioFormat, didPublish: (@Sendable () async -> Void)? = nil) throws {
        self.didPublish = didPublish
        self.request = request
        self.capture = capture
        temporary = request.destination.deletingLastPathComponent()
            .appendingPathComponent(".recording-\(UUID().uuidString).wav")
        guard !FileManager.default.fileExists(atPath: request.destination.path) else {
            throw MasterRecordingError.destinationExists
        }
        guard let normalized = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount),
              let target = AVAudioFormat(standardFormatWithSampleRate: PreparedLoop.requiredSampleRate, channels: 2),
              let converter = AVAudioConverter(from: normalized, to: target),
              let captured = AVAudioPCMBuffer(pcmFormat: normalized, frameCapacity: 2048),
              let input = AVAudioPCMBuffer(pcmFormat: normalized, frameCapacity: 2048),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else {
            throw MasterRecordingError.unsupportedFormat
        }
        self.converter = converter
        self.captured = captured
        self.input = input
        self.output = output
        converter.primeMethod = .normal
        if format.channelCount == 1 { converter.channelMap = [0, 0] }
        var settings = target.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        do { file = try AVAudioFile(forWriting: temporary, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch {
            do {
                if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
            } catch let cleanup {
                throw MasterRecordingError.fileFailure("\(error.localizedDescription); cleanup: \(cleanup.localizedDescription)")
            }
            throw MasterRecordingError.fileFailure(error.localizedDescription)
        }
    }

    func run() async throws -> MasterRecordingResult {
        do {
            while true {
                try Task.checkCancellation()
                if let failure = capture.failure { throw failure }
                if capture.read(into: captured) {
                    try consume(captured)
                } else if capture.snapshot()?.finished == true {
                    break
                } else {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            guard let snapshot = capture.snapshot(), snapshot.frames > 0 else { throw MasterRecordingError.noSamples }
            let expected = Int64(ceil(Double(snapshot.frames) * PreparedLoop.requiredSampleRate / snapshot.inputRate))
            try flush(expected: expected)
            guard written == expected else { throw MasterRecordingError.conversionFailed }
            file = nil
            try Task.checkCancellation()
            guard !FileManager.default.fileExists(atPath: request.destination.path) else { throw MasterRecordingError.destinationExists }
            try FileManager.default.moveItem(at: temporary, to: request.destination)
            await didPublish?()
            return MasterRecordingResult(destination: request.destination, frameCount: written,
                sampleRate: PreparedLoop.requiredSampleRate, channelCount: 2,
                inputFrameCount: snapshot.frames, inputSampleRate: snapshot.inputRate,
                largestInputBuffer: snapshot.largestBuffer)
        } catch {
            capture.finish()
            file = nil
            do {
                if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
            } catch let cleanup {
                throw MasterRecordingError.fileFailure("\(error.localizedDescription); cleanup: \(cleanup.localizedDescription)")
            }
            if error is CancellationError { throw error }
            if let error = error as? MasterRecordingError { throw error }
            throw MasterRecordingError.fileFailure(error.localizedDescription)
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) throws {
        if buffer.format == output.format {
            try write(buffer, limit: request.maximumFrames)
            return
        }
        var offset: AVAudioFrameCount = 0
        while true {
            try Task.checkCancellation()
            let previous = offset
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, state in
                guard offset < buffer.frameLength else { state.pointee = .noDataNow; return nil }
                let count = min(requested, input.frameCapacity, buffer.frameLength - offset)
                for channel in 0..<Int(buffer.format.channelCount) {
                    input.floatChannelData![channel].update(from: buffer.floatChannelData![channel] + Int(offset), count: Int(count))
                }
                input.frameLength = count
                offset += count
                state.pointee = .haveData
                return input
            }
            guard error == nil, status != .error else { throw MasterRecordingError.conversionFailed }
            try write(output, limit: request.maximumFrames)
            if status == .inputRanDry { break }
            guard offset > previous || output.frameLength > 0 else { throw MasterRecordingError.conversionFailed }
        }
    }

    private func flush(expected: Int64) throws {
        if input.format == output.format { return }
        while written < expected {
            try Task.checkCancellation()
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                state.pointee = .endOfStream
                return nil
            }
            guard error == nil, status != .error else { throw MasterRecordingError.conversionFailed }
            try write(output, limit: expected)
            if status == .endOfStream { break }
            guard output.frameLength > 0 else { throw MasterRecordingError.conversionFailed }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, limit: Int64) throws {
        let count = min(Int64(buffer.frameLength), limit - written)
        guard count >= 0 else { throw MasterRecordingError.durationExceeded }
        guard count > 0 else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(count) where !buffer.floatChannelData![channel][frame].isFinite {
                throw MasterRecordingError.invalidSamples
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        try file!.write(from: buffer)
        written += count
    }
}
