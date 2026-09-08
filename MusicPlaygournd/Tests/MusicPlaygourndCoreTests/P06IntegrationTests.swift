import AVFoundation
import CoreMIDI
import Darwin
import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
    @Suite struct P06ComposedLifecycleTests {
        @MainActor
        @Test(.timeLimit(.minutes(6)))
        func composedAdvancedSampleSynthesisMIDIHostedEffectRecordingAndStems() async throws {
            let package = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "SwiftMusic-P066-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer {
                do { try FileManager.default.removeItem(at: directory) }
                catch { Issue.record(error) }
            }

            let sampleURL = directory.appending(path: "decoded-bank.wav")
            try writeComposedSampleFile(at: sampleURL, frameCount: 44_100)
            let source = """
            struct Session: Music {
                let sample: Sample
                let slice: SampleSlice
                let frequencyModulation: FrequencyModulation
                let unison: Unison

                init() {
                    let url = URL(fileURLWithPath: \(sampleURL.path.debugDescription))
                    let bank = try! SampleBank([
                        SampleAsset(key: "decoded", fileURL: url, rootPitch: Pitch(midiNote: 60))
                    ])
                    sample = try! Sample(bank: bank)
                    slice = try! SampleSlice(index: 0, count: 2)
                    frequencyModulation = try! FrequencyModulation(ratio: 2, index: 1)
                    unison = try! Unison(voices: 3, detuneCents: 18)
                }

                var body: some Sound {
                    Track("Decoded Sample") {
                        try! sample.notes("C4")
                            .sampleSlice(slice)
                            .sampleStretch(to: .whole)
                            .gate(1)
                    }
                    Track("FM Unison") {
                        Synthesizer(.frequencyModulation(frequencyModulation))
                            .notes("E4")
                            .unison(unison)
                            .gain(0.03)
                            .gate(1)
                    }
                }
            }
            """
            let workspace = package.appending(path: ".build/p066-evaluator-\(UUID().uuidString)")
            let evaluator = SourceEvaluator(
                packageURL: package,
                workspace: workspace,
                swiftExecutable: "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
            )

            try await withEvaluatorShutdown(evaluator) {
                let retained = try await evaluator.evaluateRetained(
                    source: source, bpm: 120, beatsPerBar: 4, revision: 6_600
                )
                #expect(await evaluator.adopt(revision: 6_600))
                let loop = retained.loop
                #expect(loop.events.count == 2)
                let loopFinite = loop.samples.allSatisfy { $0.isFinite }
                #expect(loopFinite)
                #expect(loop.samples.contains { abs($0) > 0.0001 })

                let engine = try AudioLoopEngine()
                defer { engine.stop() }
                engine.beginUpdate(revision: 6_600)
                try engine.submit(loop: loop, revision: 6_600)
                try engine.play()

                let effectID = try #require(engine.discoverAudioEffects().first {
                    $0.id.componentManufacturer == kAudioUnitManufacturer_Apple &&
                    $0.id.componentSubType == kAudioUnitSubType_HighPassFilter
                }?.id)
                try await engine.selectAudioEffect(effectID)
                #expect(engine.snapshot().revision == 6_600)
                #expect(!engine.outputMeter().interleavedSamples.isEmpty)

                let endpoints = try VirtualMIDIEndpoints(label: "P066 composed lifecycle")
                let service = try CoreMIDIService(clientName: "MusicPlaygournd P066 Composition")
                do {
                    let destination = try endpoints.destinationID
                    try await service.setOutput(destination)
                    try await Task.sleep(for: .milliseconds(150))
                    let anchor = try engine.playbackClockAnchor()
                    await service.updateClockAnchor(anchor)
                    let onset = try anchor.hostTime(atBeat: anchor.accumulatedBeatPosition + 0.5)
                    let end = try anchor.hostTime(atBeat: anchor.accumulatedBeatPosition + 0.7)
                    let notes = try loop.events.map { event -> Int in
                        guard case .note(let note) = event.midiProjection else {
                            throw EvaluationError.invalidResult("Expected a stable projected MIDI note.")
                        }
                        return note
                    }
                    let messagesToSend = notes.map {
                        MIDIScheduledMessage(hostTime: onset, message: .noteOn(channel: 1, note: $0, velocity: 100))
                    } + notes.map {
                        MIDIScheduledMessage(hostTime: end, message: .noteOff(channel: 1, note: $0, velocity: 0))
                    }
                    try await service.send(messagesToSend, to: destination)
                    let messages = try await endpoints.waitForMessages(atLeast: 4)
                    let hasNoteOn = messages.contains {
                        if case .noteOn = $0.message { return true }
                        return false
                    }
                    let hasNoteOff = messages.contains {
                        if case .noteOff = $0.message { return true }
                        return false
                    }
                    #expect(hasNoteOn)
                    #expect(hasNoteOff)
                    await service.shutdown()
                } catch {
                    await service.shutdown()
                    throw error
                }

                let recordingURL = directory.appending(path: "master.wav")
                try engine.startRecording(
                    MasterRecordingRequest(destination: recordingURL, maximumDuration: .seconds(2))
                )
                try await Task.sleep(for: .milliseconds(400))
                let recording = try await engine.stopRecording()
                #expect(recording.frameCount > 0)
                #expect(recording.inputFrameCount > 0)
                #expect(recording.channelCount == 2)
                let masterFile = try AVAudioFile(forReading: recording.destination)
                #expect(masterFile.processingFormat.channelCount == 2)
                #expect(masterFile.length == AVAudioFramePosition(recording.frameCount))
                try requireAudiblePCM(masterFile)

                let stemsURL = directory.appending(path: "stems")
                let stemSnapshot = try await evaluator.exportStems(
                    revision: 6_600,
                    generation: 0,
                    overrides: [],
                    destination: stemsURL
                )
                #expect(stemSnapshot.revision == 6_600)
                #expect(stemSnapshot.generation == 0)
                #expect(stemSnapshot.manifest.count == 2)
                for item in stemSnapshot.manifest {
                    let stemFile = try AVAudioFile(forReading: stemsURL.appending(path: item.fileName))
                    #expect(stemFile.processingFormat.sampleRate == PreparedLoop.requiredSampleRate)
                    #expect(stemFile.processingFormat.channelCount == 2)
                    #expect(stemFile.length == AVAudioFramePosition(item.frameCount))
                    try requireAudiblePCM(stemFile)
                }
            }
        }

        @MainActor
        private func withEvaluatorShutdown(
            _ evaluator: SourceEvaluator,
            operation: () async throws -> Void
        ) async throws {
            do {
                try await operation()
                try await evaluator.shutdown()
            } catch {
                do { try await evaluator.shutdown() }
                catch { Issue.record(error) }
                throw error
            }
        }

        private func requireAudiblePCM(_ file: AVAudioFile) throws {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let channels = try #require(buffer.floatChannelData)
            let audible = (0..<Int(buffer.frameLength)).contains { abs(channels[0][$0]) > 0.00001 }
            #expect(audible)
        }

        private func writeComposedSampleFile(at url: URL, frameCount: Int) throws {
            let sampleRate = 44_100.0
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ))
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ))
            buffer.frameLength = buffer.frameCapacity
            let channels = try #require(buffer.floatChannelData)
            for frame in 0..<frameCount {
                channels[0][frame] = Float(sin(2 * Double.pi * 330 * Double(frame) / sampleRate)) * 0.2
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            file.close()
        }
    }
}
