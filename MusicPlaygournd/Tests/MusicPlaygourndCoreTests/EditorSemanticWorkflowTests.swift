import AppKit
import AVFoundation
import Foundation
import Testing
@testable import MusicPlaygourndApp
@testable import MusicPlaygourndCore

extension NativeHostTests {
    @MainActor
    struct EditorSemanticWorkflowTests {
        @Test(.timeLimit(.minutes(6)))
        func adoptedBankCompletionAndTypedDiagnosticPreserveAudio() async throws {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let directory = package.appending(path: ".build/editor-semantic-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sample = directory.appending(path: "sample.wav")
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_205))
            buffer.frameLength = 2_205
            let data = try #require(buffer.floatChannelData)[0]
            for index in 0..<2_205 { data[index] = Float(sin(Double(index) * 0.06)) * 0.1 }
            let file = try AVAudioFile(forWriting: sample, settings: format.settings)
            try file.write(from: buffer)
            file.close()
            let evaluator = SourceEvaluator(packageURL: package, workspace: directory.appending(path: "Evaluation"), swiftExecutable: "/usr/bin/swift")
            let completion = SwiftCompletionService(packageURL: package, workspace: directory.appending(path: "Completion"), sourceKitLSPExecutable: "/usr/bin/sourcekit-lsp")
            let engine = try AudioLoopEngine()
            let model = SessionModel(evaluator: evaluator, completionService: completion, engine: engine,
                hostStateStore: DocumentHostStateStore(directory: directory.appending(path: "HostState")))
            do {
                let original = """
                // 🎵
                struct Session: Music {
                    let bank: SampleBank
                    init() {
                        let url = URL(fileURLWithPath: \(sample.path.debugDescription))
                        bank = try! SampleBank([SampleAsset(key: "kick", fileURL: url), SampleAsset(key: "snare", fileURL: url)])
                    }
                    var body: some Sound { Sample(bank: bank).sampleSelection("kick") }
                }
                """
                model.source = original
                model.scheduleEvaluation(immediate: true)
                try await wait("bank adoption") {
                    model.refresh()
                    if !model.isPreparing, !model.diagnostic.isEmpty { throw EvaluationError.invalidResult(model.diagnostic) }
                    return model.currentRevision == 1 && model.controlsAvailable
                }
                let loop = try #require(model.loop)
                let location = NSMaxRange((original as NSString).range(of: ".sampleSelection(\""))
                func edit(_ range: NSRange, _ text: String) {
                    model.beforeEdit(range: range, replacement: text)
                    model.source = (model.source as NSString).replacingCharacters(in: range, with: text)
                }
                edit(NSRange(location: location, length: 4), "")
                var candidates = try await model.completions(source: model.source, utf16Offset: location)
                #expect(candidates.map(\.label) == ["kick", "snare"])
                #expect(candidates.allSatisfy { $0.replacementRange == NSRange(location: location, length: 0) })
                edit(NSRange(location: location, length: 0), "ic")
                edit(NSRange(location: location, length: 0), "k")
                edit(NSRange(location: location + 3, length: 0), "k")
                candidates = try await model.completions(source: model.source, utf16Offset: location + 4)
                #expect(candidates.map(\.label) == ["kick"])
                #expect(candidates.first?.replacementRange == NSRange(location: location, length: 4))
                #expect(model.source == original && model.loop == loop && model.currentRevision == 1)
                // Delimiter mutation invalidates the compiler-proven bank site before LSP fallback.
                edit(NSRange(location: location - 1, length: 1), " ")
                #expect(model.completionSites.isEmpty)
                model.source = original.replacingOccurrences(of: ".sampleSelection(\"kick\")", with: ".sampleSelection(\"kick\").gain(\"1 nope\")")
                model.scheduleEvaluation(immediate: true)
                try await wait("typed pattern diagnostic") { !model.isPreparing && !model.diagnostic.isEmpty }
                let range = try #require(model.diagnosticRange)
                #expect((model.source as NSString).substring(with: range) == "nope")
                model.revealDiagnostic()
                #expect(model.selectionRange == range)
                #expect(model.loop == loop && model.currentRevision == 1 && model.controlsAvailable)
                model.source = "struct Session: Music {"
                model.scheduleEvaluation(immediate: true)
                try await wait("raw Swift diagnostic") { !model.isPreparing && !model.diagnostic.isEmpty }
                #expect(model.diagnosticRange == nil)
                #expect(model.loop == loop && model.currentRevision == 1)
                try await model.shutdown()
                try FileManager.default.removeItem(at: directory)
            } catch {
                do { try await model.shutdown() } catch { Issue.record(error) }
                do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
                throw error
            }
        }

        private func wait(_ description: String, _ predicate: () throws -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(260))
            while try !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            guard try predicate() else { throw EvaluationError.timedOut(description) }
        }
    }
}
