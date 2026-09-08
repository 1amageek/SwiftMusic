import AVFoundation
import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
    @Suite struct P071SemanticEvaluationTests {
        @MainActor
        @Test(.timeLimit(.minutes(6)))
        func retainedWorkerPublishesBankMetadataAndMapsMalformedPattern() async throws {
            let package = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "SwiftMusic-P071-semantic-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer {
                do { try FileManager.default.removeItem(at: directory) }
                catch { Issue.record(error) }
            }

            let sampleURL = directory.appending(path: "bank.wav")
            try Self.writeSineFile(at: sampleURL, frameCount: 2_205)
            let source = """
            struct Session: Music {
                let bank: SampleBank

                init() {
                    let url = URL(fileURLWithPath: \(sampleURL.path.debugDescription))
                    bank = try! SampleBank([
                        SampleAsset(key: "kick", fileURL: url),
                        SampleAsset(key: "snare", fileURL: url)
                    ])
                }

                var body: some Sound {
                    Sample(bank: bank).sampleSelection("kick")
                }
            }
            """
            let workspace = package.appending(path: ".build/p071-semantic-\(UUID().uuidString)")
            let evaluator = SourceEvaluator(
                packageURL: package,
                workspace: workspace,
                swiftExecutable: "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
            )
            do {
                let revision: UInt64 = 7_101
                let retained = try await evaluator.evaluateRetained(
                    source: source, bpm: 120, beatsPerBar: 4, revision: revision
                )
                #expect(await evaluator.adopt(revision: revision))
                #expect(retained.metadata.revision == revision)
                let metadataBank = try #require(retained.metadata.sampleBanks.first)
                #expect(metadataBank.values == ["kick", "snare"])
                #expect(metadataBank.displayName == "bank.wav")
                let site = try #require(retained.metadata.sampleCompletionSites.first)
                #expect((source as NSString).substring(with: site.contentRange) == "kick")
                let values = retained.metadata.sampleCompletions(sourceID: metadataBank.sourceID, prefix: "sn")
                #expect(values.count == 1)
                #expect(values[0].replacementRange == site.contentRange)

                let malformed = source.replacingOccurrences(
                    of: ".sampleSelection(\"kick\")",
                    with: ".sampleSelection(\"kick\").gain(\"1 nope\")"
                )
                let malformedLine = try #require(
                    malformed.split(separator: "\n", omittingEmptySubsequences: false)
                        .firstIndex(where: { $0.contains(".gain") })
                ) + 1
                do {
                    _ = try await evaluator.evaluateRetained(
                        source: malformed, bpm: 120, beatsPerBar: 4, revision: revision + 1
                    )
                    Issue.record("Malformed gain pattern must fail in the worker compiler.")
                } catch let error as EvaluationError {
                    guard case let .compilerDiagnostic(message, diagnosticRange) = error else {
                        Issue.record("Expected a mapped compiler diagnostic, got: \(error.localizedDescription)")
                        throw error
                    }
                    #expect(message.contains("nope"))
                    let range = try #require(diagnosticRange)
                    #expect(range.fileID == "Session.swift" || range.fileID.hasSuffix("/Session.swift"))
                    #expect(range.line == malformedLine)
                    #expect((malformed as NSString).substring(with: range.utf16Range) == "nope")
                }
                #expect(await evaluator.controlsAvailable(revision: revision))
            } catch {
                do { try await evaluator.shutdown() }
                catch { Issue.record(error) }
                throw error
            }
            try await evaluator.shutdown()
        }

        private static func writeSineFile(at url: URL, frameCount: Int) throws {
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
                channels[0][frame] = Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate)) * 0.2
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            file.close()
        }
    }
}
