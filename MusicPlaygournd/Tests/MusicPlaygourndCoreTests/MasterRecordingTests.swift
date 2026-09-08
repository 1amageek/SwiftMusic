import AVFoundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct MasterRecordingTests {
    @Test(.timeLimit(.minutes(1)), arguments: [44_100.0, 48_000.0], [1, 2])
    func variableBuffersWriteCompleteConvertedWAV(rate: Double, channels: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let request = try MasterRecordingRequest(destination: directory.appendingPathComponent("take.wav"), maximumDuration: .seconds(2))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)))
        let capture = MasterRecordingCapture()
        try capture.begin(format: format, maximumFrames: request.maximumFrames)
        let writer = try MasterRecordingWriter(request: request, capture: capture, format: format)
        var total: Int64 = 0
        for length in [127, 4096, 777, 8192] {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)))
            buffer.frameLength = AVAudioFrameCount(length)
            for frame in 0..<length {
                buffer.floatChannelData![0][frame] = 0.25
                if channels == 2 { buffer.floatChannelData![1][frame] = -0.5 }
            }
            capture.capture(buffer, at: AVAudioTime(sampleTime: total, atRate: rate))
            total += Int64(length)
        }
        capture.finish()
        let result = try await writer.run()
        #expect(result.inputFrameCount == total)
        #expect(result.largestInputBuffer == 8192)
        #expect(result.frameCount == Int64(ceil(Double(total) * 44100 / rate)))
        let file = try AVAudioFile(forReading: result.destination)
        #expect(file.length == result.frameCount)
        #expect(file.processingFormat.sampleRate == 44100)
        #expect(file.processingFormat.channelCount == 2)
        let read = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: read)
        for frame in 100..<Int(read.frameLength) - 100 {
            #expect(abs(read.floatChannelData![0][frame] - 0.25) < 0.002)
            #expect(abs(read.floatChannelData![1][frame] - (channels == 1 ? 0.25 : -0.5)) < 0.002)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["take.wav"])
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidCaptureFailsWholeTakeAndCleansTemporaryFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        for expected in [MasterRecordingError.discontinuousTime, .captureOverrun, .durationExceeded, .unsupportedFormat, .invalidSamples] {
            let request = try MasterRecordingRequest(destination: directory.appendingPathComponent("take.wav"), maximumDuration: .seconds(1))
            let capture = MasterRecordingCapture()
            try capture.begin(format: format, maximumFrames: expected == .durationExceeded ? 1 : 1_000_000)
            let writer = try MasterRecordingWriter(request: request, capture: capture, format: format)
            let count = expected == .captureOverrun ? 2048 * 65 : 4
            let actualFormat = expected == .unsupportedFormat ? try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)) : format
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: actualFormat, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<2 {
                for frame in 0..<count { buffer.floatChannelData![channel][frame] = 0 }
            }
            if expected == .invalidSamples { buffer.floatChannelData![0][0] = .nan }
            capture.capture(buffer, at: AVAudioTime(sampleTime: 0, atRate: 44100))
            if expected == .discontinuousTime { capture.capture(buffer, at: AVAudioTime(sampleTime: 9, atRate: 44100)) }
            capture.finish()
            await #expect(throws: expected) { try await writer.run() }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }
    @Test(.timeLimit(.minutes(1)))
    func cancellationAndExistingDestinationKeepFilesIntact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let destination = directory.appendingPathComponent("take.wav")
        let request = try MasterRecordingRequest(destination: destination, maximumDuration: .seconds(1))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let capture = MasterRecordingCapture()
        try capture.begin(format: format, maximumFrames: request.maximumFrames)
        let writer = try MasterRecordingWriter(request: request, capture: capture, format: format)
        let task = Task { try await writer.run() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let original = Data([1, 2, 3])
        try original.write(to: destination)
        #expect(throws: MasterRecordingError.destinationExists) {
            try MasterRecordingWriter(request: request, capture: capture, format: format)
        }
        #expect(try Data(contentsOf: destination) == original)
        #expect(throws: MasterRecordingError.invalidRequest) {
            try MasterRecordingRequest(destination: destination, maximumDuration: .zero)
        }
    }

}
