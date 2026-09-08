import Darwin
import AVFoundation
import Foundation
import SwiftMusic
import Synchronization
import Testing
@testable import MusicPlaygourndCore

struct StemExportTests {
    @Test(.timeLimit(.minutes(3)))
    func capturesStableTrackBoundariesBeforeSendAndNestedMixing() throws {
        struct Routed: Sound {
            var body: some Sound {
                Track("Lead/Ω") {
                    Synthesizer(.sine).notes("C4")
                }
                .trackLevel(0.5)
                .send(to: "room", level: 0.5, placement: .postFader)
                Track("Muted") {
                    Synthesizer(.square).notes("C2")
                }
                .trackMuted()
                BusReturn("room")
            }
        }

        let routed = try SoundCompiler().compile(Routed())
        let session = try LoopRenderSession(sound: routed, bpm: 240, beatsPerBar: 4)
        let stems = try session.renderStems()
        #expect(stems.map(\.trackID) == [0, 1])
        #expect(stems.map(\.label) == ["Lead/Ω", "Muted"])
        #expect(stems.allSatisfy { $0.frameCount == 44_100 })
        #expect(stems.allSatisfy { $0.samples.allSatisfy(\.isFinite) })
        #expect(stems[0].samples.contains { abs($0) > 0.001 })
        #expect(stems[1].samples.allSatisfy { $0 == 0 })

        let unsent = Track("Lead/Ω") {
            Synthesizer(.sine).notes("C4")
        }
        .trackLevel(0.5)
        let expected = try LoopRenderSession(
            sound: SoundCompiler().compile(unsent), bpm: 240, beatsPerBar: 4
        ).renderStems()
        #expect(expected.count == 1)
        #expect(maximumError(stems[0].samples, expected[0].samples) < 0.000001)

        struct Nested: Sound {
            var body: some Sound {
                Track("Outer") {
                    Track("Solo") {
                        Synthesizer(.sine).notes("E4")
                    }
                    .trackSolo()
                    Track("Other") {
                        Synthesizer(.square).notes("G2")
                    }
                }
            }
        }
        let nested = try LoopRenderSession(
            sound: SoundCompiler().compile(Nested()), bpm: 240, beatsPerBar: 4
        ).renderStems()
        #expect(nested.map(\.trackID) == [0, 1, 2])
        #expect(nested[1].samples.contains { abs($0) > 0.001 })
        #expect(nested[2].samples.allSatisfy { $0 == 0 })
        #expect(maximumError(nested[0].samples, nested[1].samples) < 0.000001)
    }

    @Test(.timeLimit(.minutes(3)))
    func reusesPreparedAssetsAndAppliesTrackOverrideToStems() throws {
        let loader = CountingLoader()
        let sampleURL = URL(fileURLWithPath: "/virtual/stem-fixture.wav")
        let sample = try Sample(file: sampleURL, rootPitch: Pitch(midiNote: 60))
        let track = Track("Sample") {
            sample.notes("C4")
        }
        .trackLevel(0.8)
        let sound = try SoundCompiler().compile(track)
        let session = try LoopRenderSession(
            sound: sound, bpm: 240, beatsPerBar: 4, revision: 5, sampleLoader: loader
        )

        let baseline = try session.renderStems()
        let address = try #require(session.catalog.descriptors.first {
            $0.address.target == .track(0) && $0.address.parameter == .trackLevel
        }?.address)
        let changed = try session.renderStems(overrides: [
            LiveControlOverride(address: address, value: .number(0.2))
        ])
        let released = try session.renderStems()

        #expect(baseline.count == 1)
        #expect(changed.count == 1)
        #expect(released == baseline)
        #expect(maximumError(changed[0].samples, baseline[0].samples) > 0.01)
        #expect(loader.requests.withLock { $0.count } == 1)
    }

    @Test(.timeLimit(.minutes(3)))
    func exportsReopenableFloat32WAVsAndPublishesNoPartialSetOnFailureOrCancel() async throws {
        struct Session: Sound {
            var body: some Sound {
                Track("Lead") { Synthesizer(.sine).notes("C4") }
                Track("Bass") { Synthesizer(.triangle).notes("C2") }
            }
        }
        let session = try LoopRenderSession(
            sound: SoundCompiler().compile(Session()), bpm: 240, beatsPerBar: 4
        )
        let stems = try session.renderStems()
        let manager = FileManager.default
        let token = UUID().uuidString
        let destination = manager.temporaryDirectory.appending(path: "stems-\(token)")
        defer {
            if manager.fileExists(atPath: destination.path) {
                do {
                    try manager.removeItem(at: destination)
                } catch {
                    Issue.record("Failed to remove exported stem destination: \(error)")
                }
            }
        }

        let manifest = try StemExporter.export(stems, to: destination)
        #expect(manifest.map(\.trackID) == stems.map(\.trackID))
        #expect(manifest.allSatisfy { !$0.fileName.contains("/") })
        for (stem, item) in zip(stems, manifest) {
            let fileURL = destination.appending(path: item.fileName)
            let file = try AVAudioFile(forReading: fileURL)
            #expect(file.processingFormat.sampleRate == PreparedLoop.requiredSampleRate)
            #expect(file.processingFormat.channelCount == 2)
            #expect(Int(file.length) == stem.frameCount)
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(stem.frameCount)
            ))
            try file.read(into: buffer)
            let channels = try #require(buffer.floatChannelData)
            var error: Float = 0
            for frame in 0..<stem.frameCount {
                error = max(error, abs(channels[0][frame] - stem.samples[frame * 2]))
                error = max(error, abs(channels[1][frame] - stem.samples[frame * 2 + 1]))
            }
            #expect(error < 0.000001)
            file.close()
        }

        let unsynchronized = try PreparedStem(
            trackID: 99,
            label: "Mismatched",
            sampleRate: PreparedLoop.requiredSampleRate,
            bpm: 120,
            beatsPerBar: 4,
            beatCount: 2,
            samples: [Float](repeating: 0, count: stems[0].samples.count)
        )
        let mismatchedDestination = manager.temporaryDirectory
            .appending(path: "mismatched-stems-\(token)")
        #expect(throws: StemExportError.self) {
            try StemExporter.export([stems[0], unsynchronized], to: mismatchedDestination)
        }
        #expect(!manager.fileExists(atPath: mismatchedDestination.path))

        let existing = manager.temporaryDirectory.appending(path: "existing-stems-\(token)")
        try manager.createDirectory(at: existing, withIntermediateDirectories: false)
        defer {
            if manager.fileExists(atPath: existing.path) {
                do {
                    try manager.removeItem(at: existing)
                } catch {
                    Issue.record("Failed to remove existing stem fixture: \(error)")
                }
            }
        }
        #expect(throws: StemExportError.destinationExists) {
            try StemExporter.export(stems, to: existing)
        }

        let cancelled = manager.temporaryDirectory.appending(path: "cancelled-stems-\(token)")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try StemExporter.export(stems, to: cancelled)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!manager.fileExists(atPath: cancelled.path))
        let stagingPrefix = ".\(cancelled.lastPathComponent).staging-"
        let siblings = try manager.contentsOfDirectory(
            at: cancelled.deletingLastPathComponent(), includingPropertiesForKeys: nil
        )
        #expect(!siblings.contains { $0.lastPathComponent.hasPrefix(stagingPrefix) })
    }

    private func maximumError(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count else { return .greatestFiniteMagnitude }
        return zip(lhs, rhs).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    private final class CountingLoader: SampleLoading {
        let requests = Mutex<[SampleLoadRequest]>([])

        func load(_ request: SampleLoadRequest) throws -> LoadedSample {
            requests.withLock { $0.append(request) }
            return try LoadedSample(
                samples: Array(repeating: Float(0.25), count: 44_100),
                channelCount: 1,
                sampleRate: PreparedLoop.requiredSampleRate
            )
        }
    }
}

extension NativeHostTests {
    struct StemExportEvaluationTests {
        @MainActor
        @Test(.timeLimit(.minutes(4)))
        func acceptedExportKeepsItsWorkerAndIdentityAcrossLaterCodeAdoption() async throws {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let workspace = package.appending(path: ".build/stem-lifetime-\(UUID().uuidString)")
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let evaluator = SourceEvaluator(packageURL: package, workspace: workspace,
                swiftExecutable: "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift")
            var pausedPID: pid_t?
            var export: Task<StemExportSnapshot, Error>?
            defer {
                if let pausedPID { kill(pausedPID, SIGCONT) }
                if FileManager.default.fileExists(atPath: destination.path) {
                    do { try FileManager.default.removeItem(at: destination) } catch { Issue.record(error) }
                }
            }
            let source = """
            struct Session: Music {
                var body: some Sound { Track("Old") { Synthesizer(.sine).notes("C4").gain(0.01) } }
            }
            """
            do {
                _ = try await evaluator.evaluateRetained(source: source, bpm: 120, beatsPerBar: 4, revision: 1)
                #expect(await evaluator.adopt(revision: 1))
                _ = try await evaluator.render(overrides: [], revision: 1, generation: 1)
                _ = try await evaluator.evaluateRetained(source: source.replacingOccurrences(of: "Old", with: "New"),
                    bpm: 120, beatsPerBar: 4, revision: 2)
                let pid = try #require(await evaluator.workerStateForTests().pid)
                #expect(kill(pid, SIGSTOP) == 0)
                pausedPID = pid
                let task = Task { try await evaluator.exportStems(revision: 1, generation: 1,
                    overrides: [], destination: destination) }
                export = task
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while await evaluator.workerStateForTests().exporting != 1, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(await evaluator.workerStateForTests().exporting == 1)
                #expect(!FileManager.default.fileExists(atPath: destination.path))
                #expect(await evaluator.adopt(revision: 2))
                #expect(await evaluator.workerStateForTests().retired == 1)
                let newLoop = try await evaluator.render(overrides: [], revision: 2, generation: 1)
                #expect(!newLoop.samples.isEmpty)
                #expect(kill(pid, SIGCONT) == 0)
                pausedPID = nil
                let result = try await task.value
                #expect(result.revision == 1 && result.generation == 1)
                #expect(result.manifest.first?.label == "Old")
                #expect(result.manifest.allSatisfy { FileManager.default.fileExists(atPath: destination.appendingPathComponent($0.fileName).path) })
                #expect(await evaluator.workerStateForTests().retired == nil)
                #expect(kill(pid, 0) == -1 && errno == ESRCH)
                _ = try await evaluator.render(overrides: [], revision: 2, generation: 2)
                try await evaluator.shutdown()
            } catch {
                if let pausedPID { kill(pausedPID, SIGCONT) }
                pausedPID = nil
                export?.cancel()
                if let export {
                    do { _ = try await export.value } catch is CancellationError {} catch { Issue.record(error) }
                }
                try await evaluator.shutdown()
                throw error
            }
        }

        @Test(.timeLimit(.minutes(4)))
        func retainedWorkerExportsStemsWithoutReplacingItsPreparedLoop() async throws {
            let package = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let workspace = package.appending(path: ".build/stem-evaluator-\(UUID().uuidString)")
            let evaluator = SourceEvaluator(
                packageURL: package,
                workspace: workspace,
                swiftExecutable: "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
            )
            let initialDestination = FileManager.default.temporaryDirectory
                .appending(path: "worker-stems-initial-\(UUID().uuidString)")
            let currentDestination = FileManager.default.temporaryDirectory
                .appending(path: "worker-stems-current-\(UUID().uuidString)")
            defer {
                for destination in [initialDestination, currentDestination] {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        do {
                            try FileManager.default.removeItem(at: destination)
                        } catch {
                            Issue.record("Failed to remove worker stem destination: \(error)")
                        }
                    }
                }
            }
            let source = """
            struct Session: Music {
                var body: some Sound {
                    Track("Lead") { Synthesizer(.sine).notes("C4") }
                    Track("Muted") { Synthesizer(.square).notes("C2") }.trackMuted()
                }
            }
            """
            do {
                let retained = try await evaluator.evaluateRetained(
                    source: source, bpm: 240, beatsPerBar: 4, revision: 651
                )
                #expect(await evaluator.adopt(revision: 651))
                let initialManifest = try await evaluator.exportStems(
                    revision: 651, generation: 0, overrides: [], destination: initialDestination
                )
                #expect(initialManifest.revision == 651)
                #expect(initialManifest.generation == 0)
                #expect(initialManifest.manifest.map(\.trackID) == [0, 1])
                #expect(initialManifest.manifest.allSatisfy { FileManager.default.fileExists(
                    atPath: initialDestination.appending(path: $0.fileName).path
                ) })
                _ = try await evaluator.render(overrides: [], revision: 651, generation: 1)
                let manifest = try await evaluator.exportStems(
                    revision: 651, generation: 1, overrides: [], destination: currentDestination
                )
                #expect(manifest.revision == 651)
                #expect(manifest.generation == 1)
                #expect(manifest.manifest.map(\.trackID) == [0, 1])
                #expect(manifest.manifest.allSatisfy { FileManager.default.fileExists(
                    atPath: currentDestination.appending(path: $0.fileName).path
                ) })
                let loop = try await evaluator.render(overrides: [], revision: 651, generation: 2)
                let loopMatchesRetained = loop == retained.loop
                #expect(loopMatchesRetained)
                try await evaluator.shutdown()
            } catch {
                try await evaluator.shutdown()
                throw error
            }
        }
    }
}
