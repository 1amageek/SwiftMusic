import AVFoundation
import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
    @Suite struct AdvancedSampleEvaluationTests {
        @MainActor
        @Test(.timeLimit(.minutes(6)))
        func evaluatedBankSampleProcessingReachesNativePlaybackAndRetainsPriorLoopOnFailure() async throws {
            let package = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "SwiftMusic-P061-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer {
                do { try FileManager.default.removeItem(at: directory) }
                catch { Issue.record(error) }
            }
            let sampleURL = directory.appending(path: "bank.wav")
            try writeSineFile(at: sampleURL, frameCount: 22_050)

            let source = """
            struct Session: Music {
                let bank: SampleBank
                let slice: SampleSlice
                let granular: GranularPlayback

                init() {
                    let url = URL(fileURLWithPath: \(sampleURL.path.debugDescription))
                    bank = try! SampleBank([
                        SampleAsset(key: "a", fileURL: url),
                        SampleAsset(key: "b", fileURL: url, rootPitch: Pitch(midiNote: 72))
                    ])
                    slice = try! SampleSlice(index: 0, count: 2)
                    granular = try! GranularPlayback(
                        grainDuration: .milliseconds(20),
                        overlap: 0.5,
                        positionJitter: 0,
                        seed: 9
                    )
                }

                var body: some Sound {
                    try! Sample(bank: bank)
                        .notes("C4 D4")
                        .sampleSelection("<a b>")
                        .sampleSlice(slice)
                        .chopped(into: 2)
                        .sampleStretch(to: .whole)
                        .granular(granular)
                }
            }
            """
            let workspace = package.appending(path: ".build/p061-evaluator-\(UUID().uuidString)")
            let evaluator = SourceEvaluator(
                packageURL: package,
                workspace: workspace,
                swiftExecutable: "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
            )
            try await withEvaluatorShutdown(evaluator) {
                let retained = try await evaluator.evaluateRetained(
                    source: source, bpm: 120, beatsPerBar: 4, revision: 601
                )
                #expect(await evaluator.adopt(revision: 601))
                let loop = retained.loop
                #expect(loop.beatCount == 8)
                #expect(loop.events.count == 8)
                #expect(loop.events.map(\.startBeat) == [0, 1, 2, 3, 4, 5, 6, 7])
                #expect(loop.events.allSatisfy { abs($0.durationBeats - 1) < 1e-12 })
                #expect(loop.samples.count == 352_800)
                let loopFinite = loop.samples.allSatisfy { $0.isFinite }
                #expect(loopFinite)
                #expect(loop.samples.contains { abs($0) > 0.0001 })

                let engine = try AudioLoopEngine()
                defer { engine.stop() }
                engine.beginUpdate(revision: 601)
                try engine.submit(loop: loop, revision: 601)
                try engine.prepareOfflineRenderingForTests()
                try engine.play()
                let nativePCM = try engine.renderOfflineForTests(frameCount: 4_096)
                #expect(nativePCM.count == 8_192)
                let nativeFinite = nativePCM.allSatisfy { $0.isFinite }
                #expect(nativeFinite)
                #expect(nativePCM.contains { abs($0) > 0.0001 })
                #expect(engine.snapshot().revision == 601)

                let invalidSource = source.replacingOccurrences(
                    of: sampleURL.path, with: sampleURL.path + ".missing"
                )
                do {
                    _ = try await evaluator.evaluate(source: invalidSource, bpm: 120, beatsPerBar: 4)
                    Issue.record("A missing decoded asset must fail evaluation")
                } catch {
                    #expect(!error.localizedDescription.isEmpty)
                }
                let restored = try await evaluator.render(overrides: [], revision: 601, generation: 2)
                let restoredBaseline = restored == loop
                #expect(restoredBaseline)
                #expect(engine.snapshot().revision == 601)
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

        private func writeSineFile(at url: URL, frameCount: Int) throws {
            let rate = 44_100.0
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: rate,
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
                channels[0][frame] = Float(sin(2 * Double.pi * 440 * Double(frame) / rate)) * 0.3
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            file.close()
        }
    }
}
