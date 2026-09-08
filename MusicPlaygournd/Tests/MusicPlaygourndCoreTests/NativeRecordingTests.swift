import AVFoundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
    @MainActor struct NativeRecordingTests {
        @Test(.timeLimit(.minutes(1)))
        func hardwareTapRecordsPostEffectAndCancelPreservesPlayback() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
            let engine = try AudioLoopEngine()
            defer { engine.stop() }
            let loop = try LoopRenderer().render(SoundCompiler().compile(
                Synthesizer(.sine).notes("A3").gain(0.02)), bpm: 120, beatsPerBar: 4)
            engine.beginUpdate(revision: 31)
            try engine.submit(loop: loop, revision: 31)
            try engine.play()
            try await Task.sleep(for: .milliseconds(300))
            let dry = try await record(engine, at: directory.appendingPathComponent("dry.wav"))
            let id = try #require(engine.discoverAudioEffects().first {
                $0.id.componentManufacturer == kAudioUnitManufacturer_Apple && $0.id.componentSubType == kAudioUnitSubType_HighPassFilter
            }).id
            try await engine.selectAudioEffect(id)
            try await Task.sleep(for: .milliseconds(300))
            let wet = try await record(engine, at: directory.appendingPathComponent("wet.wav"))
            #expect(try rms(wet.destination) < rms(dry.destination) * 0.7)
            #expect(wet.inputFrameCount > 0)
            #expect(wet.frameCount == Int64(ceil(Double(wet.inputFrameCount) * 44100 / wet.inputSampleRate)))
            #expect(wet.largestInputBuffer > 0)
            print("Native recording: input \(wet.inputSampleRate) Hz, largest callback \(wet.largestInputBuffer) frames, input \(wet.inputFrameCount), WAV \(wet.frameCount) frames")
            #expect(!engine.outputMeter().interleavedSamples.isEmpty)
            try engine.startRecording(MasterRecordingRequest(destination: directory.appendingPathComponent("cancel.wav"), maximumDuration: .seconds(3)))
            try await Task.sleep(for: .milliseconds(100))
            try await engine.cancelRecording()
            try await engine.cancelRecording()
            #expect(!engine.isRecording)
            #expect(engine.snapshot().isPlaying)
            #expect(engine.snapshot().revision == 31)
            #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["dry.wav", "wet.wav"])
        }

        @Test(.timeLimit(.minutes(1)))
        func releasingEngineCancelsOwnedWriterAndRemovesTemporaryFile() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
            var engine: AudioLoopEngine? = try AudioLoopEngine()
            weak let released = engine
            try engine!.startRecording(MasterRecordingRequest(destination: directory.appendingPathComponent("take.wav"), maximumDuration: .seconds(1)))
            engine = nil
            #expect(released == nil)
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }

        @Test(.timeLimit(.minutes(1)))
        func cancelRacingPublishedStopRemovesFileAndAllowsNextTake() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
            let engine = try AudioLoopEngine()
            defer { engine.stop() }
            let loop = try LoopRenderer().render(SoundCompiler().compile(Synthesizer(.sine).gain(0.001)), bpm: 120, beatsPerBar: 4)
            engine.beginUpdate(revision: 1)
            try engine.submit(loop: loop, revision: 1)
            try engine.play()
            let gate = PublicationGate()
            engine.recordingDidPublish = { await gate.pause() }
            let destination = directory.appendingPathComponent("cancelled.wav")
            try engine.startRecording(MasterRecordingRequest(destination: destination, maximumDuration: .seconds(2)))
            try await Task.sleep(for: .milliseconds(200))
            let stop = Task { try await engine.stopRecording() }
            while !(await gate.entered) { try await Task.sleep(for: .milliseconds(5)) }
            #expect(FileManager.default.fileExists(atPath: destination.path))
            let cancel = Task { try await engine.cancelRecording() }
            while !engine.recordingCancellationRequested { await Task.yield() }
            await gate.release()
            try await cancel.value
            await #expect(throws: CancellationError.self) { try await stop.value }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            #expect(!engine.isRecording)
            engine.recordingDidPublish = nil
            try engine.startRecording(MasterRecordingRequest(destination: directory.appendingPathComponent("next.wav"), maximumDuration: .seconds(1)))
            try await engine.cancelRecording()
            #expect(!engine.isRecording)
        }

        private actor PublicationGate {
            var entered = false
            private var continuation: CheckedContinuation<Void, Never>?
            func pause() async {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    entered = true
                }
            }
            func release() { continuation?.resume(); continuation = nil }
        }

        private func record(_ engine: AudioLoopEngine, at destination: URL) async throws -> MasterRecordingResult {
            try engine.startRecording(MasterRecordingRequest(destination: destination, maximumDuration: .seconds(3)))
            try await Task.sleep(for: .milliseconds(400))
            let meter = engine.outputMeter().interleavedSamples
            let meterRMS = sqrt(meter.reduce(0.0) { $0 + Double($1 * $1) } / Double(meter.count))
            let result = try await engine.stopRecording()
            let fileRMS = try rms(result.destination)
            #expect(fileRMS > meterRMS * 0.7 && fileRMS < meterRMS * 1.3)
            return result
        }

        private func rms(_ url: URL) throws -> Double {
            let file = try AVAudioFile(forReading: url)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            #expect(buffer.frameLength > 0)
            var sum = 0.0
            for frame in 0..<Int(buffer.frameLength) { sum += pow(Double(buffer.floatChannelData![0][frame]), 2) }
            return sqrt(sum / Double(buffer.frameLength))
        }
    }
}
