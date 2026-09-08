import AVFoundation
import Foundation
import Testing
@testable import MusicPlaygourndApp
@testable import MusicPlaygourndCore

extension NativeHostTests {
    struct SessionModelLiveControlTests {
        @MainActor
        @Test(.timeLimit(.minutes(4)))
        func adoptedCatalogOverridesAndReleasesActualOfflinePCM() async throws {
            try await Self.withHarness { harness in
                let source = Self.baseSource
                try await Self.adopt(harness, source: source, revision: 1)
                let gain = try Self.requireAddress(harness.model,
                    target: .source(0), parameter: .gain)
                let stale = LiveControlAddress(revision: 0, target: .source(0), parameter: .gain)

                let baseline = try Self.render(harness.engine)
                let baselineEnergy = Self.energy(baseline)
                #expect(baselineEnergy > 0.0001)
                let sourceBefore = harness.model.source
                let revisionBefore = harness.model.revision

                try harness.model.setControl(gain, value: .number(0.2))
                try await Self.waitUntil("gain override generation") {
                    harness.model.refresh()
                    return harness.model.overrideGeneration == 1
                        && harness.engine.snapshot().overrideGeneration == 1
                }
                let overridden = try Self.render(harness.engine)
                let overriddenEnergy = Self.energy(overridden)
                #expect(overriddenEnergy < baselineEnergy * 0.55)
                #expect(harness.model.source == sourceBefore)
                #expect(harness.model.revision == revisionBefore)
                #expect(harness.engine.snapshot().revision == 1)

                try harness.model.setControl(gain, value: nil)
                try await Self.waitUntil("gain release generation") {
                    harness.model.refresh()
                    return harness.model.overrideGeneration == 2
                        && harness.engine.snapshot().overrideGeneration == 2
                }
                let released = try Self.render(harness.engine)
                #expect(Self.energy(released) > overriddenEnergy * 1.7)

                harness.model.diagnostic = ""
                try harness.model.setControl(gain, value: .number(-1))
                try await Self.waitUntil("invalid override failure") {
                    harness.model.refresh()
                    return !harness.model.diagnostic.isEmpty
                        && harness.model.controlsAvailable
                        && harness.engine.snapshot().overrideGeneration == 2
                }
                #expect(harness.engine.snapshot().revision == 1)
                let recoveredGeneration = harness.engine.snapshot().overrideGeneration + 2
                try harness.model.setControl(gain, value: .number(0.35))
                try await Self.waitUntil("valid override recovery") {
                    harness.model.refresh()
                    return harness.model.controlsAvailable
                        && harness.engine.snapshot().overrideGeneration == recoveredGeneration
                }
                let recovered = try Self.render(harness.engine)
                #expect(Self.energy(recovered) < baselineEnergy * 0.7)

                do {
                    try harness.model.setControl(stale, value: .number(0.5))
                    Issue.record("An address from an older revision must be rejected")
                } catch let error as LiveControlError {
                    #expect(error == .staleRevision(expected: 1, actual: 0))
                } catch {
                    Issue.record("Expected staleRevision, got \(error)")
                }

                harness.model.bpm = 137
                harness.model.lowPass = 800
                harness.model.delayMix = 0.25
                harness.model.reverbMix = 0.2
                let expectedMasters = harness.engine.masterParametersForTests
                #expect(abs(expectedMasters.rate - Float(137.0 / 120.0)) < 0.00001)
                #expect(expectedMasters.lowPass == 800)
                #expect(expectedMasters.delay == 0.25)
                #expect(expectedMasters.reverb == 0.2)

                let masterRate = try Self.requireAddress(harness.model,
                    target: .master, parameter: .playbackRate)
                try harness.model.setControl(masterRate, value: .number(1.5))
                #expect(abs(harness.engine.masterParametersForTests.rate - 1.5) < 0.00001)
                try harness.model.setControl(masterRate, value: nil)
                #expect(abs(harness.engine.masterParametersForTests.rate - Float(137.0 / 120.0)) < 0.00001)

                harness.model.source = Self.alternateSource
                harness.model.scheduleEvaluation(immediate: true)
                try await Self.waitUntil("second revision prepared", timeout: .seconds(45)) {
                    harness.model.refresh()
                    return !harness.model.isPreparing
                }
                #expect(harness.model.diagnostic.isEmpty)
                try harness.engine.play()
                try await Self.waitUntil("second revision adoption", timeout: .seconds(45)) {
                    harness.model.refresh()
                    return harness.model.currentRevision == 2
                        && harness.model.controlsAvailable
                }
                harness.engine.stop()
                harness.model.refresh()
                let adoptedMasters = harness.engine.masterParametersForTests
                #expect(abs(adoptedMasters.rate - expectedMasters.rate) < 0.00001)
                #expect(adoptedMasters.lowPass == expectedMasters.lowPass)
                #expect(adoptedMasters.delay == expectedMasters.delay)
                #expect(adoptedMasters.reverb == expectedMasters.reverb)

                let oldMaster = masterRate
                do {
                    try harness.model.setControl(oldMaster, value: .number(1.1))
                    Issue.record("A master address from the previous revision must be rejected")
                } catch let error as LiveControlError {
                    #expect(error == .staleRevision(expected: 2, actual: 1))
                } catch {
                    Issue.record("Expected stale master revision, got \(error)")
                }

                let oldLoop = try #require(harness.model.loop)
                harness.model.diagnostic = ""
                harness.model.source = "struct Session: Music {"
                harness.model.scheduleEvaluation(immediate: true)
                try await Self.waitUntil("failed edit retention", timeout: .seconds(45)) {
                    harness.model.refresh()
                    return harness.model.revision == 3
                        && harness.model.currentRevision == 2
                        && !harness.model.isPreparing
                        && !harness.model.diagnostic.isEmpty
                }
                #expect(harness.model.controlsAvailable)
                #expect(harness.engine.snapshot().revision == 2)
                let retainsOldLoop = harness.model.loop == oldLoop
                #expect(retainsOldLoop)

                let currentGain = try Self.requireAddress(harness.model,
                    target: .source(0), parameter: .gain)
                let generation = harness.engine.snapshot().overrideGeneration + 1
                try harness.model.setControl(currentGain, value: .number(0.4))
                try await Self.waitUntil("retained worker override") {
                    harness.model.refresh()
                    return harness.model.controlsAvailable
                        && harness.engine.snapshot().overrideGeneration == generation
                }

                try harness.engine.play()
                harness.model.refresh()
                try await Self.waitUntil("initial playback") {
                    harness.model.refresh()
                    return harness.engine.snapshot().isPlaying
                }
                let retained = try #require(harness.model.loop)

                harness.model.source = Self.baseSource
                harness.model.scheduleEvaluation(immediate: true)
                try await Self.waitUntil("prepared candidate waiting for a bar", timeout: .seconds(45)) {
                    harness.model.refresh()
                    return !harness.model.isPreparing && harness.model.diagnostic.isEmpty
                        && harness.model.currentRevision != harness.model.revision
                }
                harness.model.source = "struct Session: Music {"
                harness.model.scheduleEvaluation(immediate: true)
                let failedRevision = harness.model.revision
                let retainedRevision = try #require(harness.model.currentRevision)

                try await Self.waitUntil("pending candidate invalidation", timeout: .seconds(45)) {
                    harness.model.refresh()
                    return harness.model.revision == failedRevision
                        && harness.model.currentRevision == retainedRevision
                        && !harness.model.isPreparing
                        && !harness.model.diagnostic.isEmpty
                }
                #expect(harness.engine.snapshot().revision == retainedRevision)
                #expect(harness.engine.snapshot().isPlaying)
                let retainsPendingLoop = harness.model.loop == retained
                #expect(retainsPendingLoop)
                #expect(harness.model.controlsAvailable)

                harness.model.source = Self.recoverySource
                harness.model.scheduleEvaluation(immediate: true)
                let recoveredRevision = harness.model.revision
                try await Self.waitUntil("recovered adopted playback", timeout: .seconds(45)) {
                    _ = try harness.engine.renderOfflineForTests(frameCount: 4096)
                    harness.model.refresh()
                    return harness.model.revision == recoveredRevision
                        && harness.model.currentRevision == recoveredRevision
                        && harness.model.controlsAvailable
                }
                #expect(harness.engine.snapshot().revision == recoveredRevision)
                #expect(harness.engine.snapshot().isPlaying)
                #expect(harness.model.loop?.samples.contains { abs($0) > 0.0001 } == true)
            }
        }

        @MainActor
        @Test(.timeLimit(.minutes(4)))
        func recordingAndExportPreserveAdoptedControlsAcrossFailedRequests() async throws {
            try await Self.withHarness { harness in
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
                let source = """
                struct Session: Music {
                    var body: some Sound {
                        Track("Lead") { Synthesizer(.sine).notes("C4").gain(0.01) }
                    }
                }
                """
                try await Self.adopt(harness, source: source, revision: 1)
                let initial = try await harness.model.exportStems(to: directory.appendingPathComponent("initial"))
                #expect(initial.revision == 1 && initial.generation == 0 && initial.manifest.count == 1)
                #expect(!harness.model.isExportingStems)
                let gain = try Self.requireAddress(harness.model, target: .source(0), parameter: .gain)
                try harness.model.setControl(gain, value: .number(0.005))
                try await Self.waitUntil("first control adoption") {
                    harness.model.refresh()
                    return harness.model.overrideGeneration == 1
                }
                let controlled = try await harness.model.exportStems(to: directory.appendingPathComponent("controlled"))
                #expect(controlled.revision == 1 && controlled.generation == 1)
                try harness.model.setControl(gain, value: .number(-1))
                try await Self.waitUntil("failed control request") { !harness.model.diagnostic.isEmpty }
                let retainedExport = try await harness.model.exportStems(to: directory.appendingPathComponent("retained"))
                #expect(retainedExport.revision == 1 && retainedExport.generation == 1)
                #expect(harness.model.overrideGeneration == 1)
                try harness.model.setControl(gain, value: .number(0.004))
                try await Self.waitUntil("control after exports") {
                    harness.model.refresh()
                    return harness.model.overrideGeneration == 3
                }
                try harness.engine.play()
                try harness.model.startRecording(to: directory.appendingPathComponent("master.wav"), maximumDuration: .seconds(2))
                try await Task.sleep(for: .milliseconds(250))
                let result = try await harness.model.stopRecording()
                #expect(result.frameCount > 0)
                #expect(!harness.model.isRecording)
                #expect(harness.engine.snapshot().isPlaying)
                #expect(harness.model.source == source)
                #expect(harness.model.currentRevision == 1)
                try harness.model.startRecording(to: directory.appendingPathComponent("shutdown.wav"), maximumDuration: .seconds(2))
                try await harness.model.shutdown()
                #expect(!harness.model.isRecording)
                #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("shutdown.wav").path))
            }
        }

        @MainActor
        @Test(.timeLimit(.minutes(4)))
        func atomicXYAndLearnRestoreRetainSourceAndPCM() async throws {
            let midi = SessionMIDIService()
            let harness = try Harness(midiService: midi)
            do {
                try await Self.adopt(harness, source: Self.baseSource, revision: 1)
                let model = harness.model
                let source = model.source
                let gain = try Self.requireAddress(model, target: .source(0), parameter: .gain)
                let pan = try Self.requireAddress(model, target: .source(0), parameter: .pan)
                model.xyX = gain; model.xyY = pan
                try model.setXY(x: 0.1, y: 1)
                try await Self.waitUntil("atomic XY generation") {
                    model.refresh(); return model.overrideGeneration == 1
                }
                #expect(model.controlValue(try #require(model.controlCatalog?.descriptor(for: gain))) == 0.2)
                #expect(model.controlValue(try #require(model.controlCatalog?.descriptor(for: pan))) == 1)
                let pcm = try Self.render(harness.engine)
                let left = stride(from: 0, to: pcm.count, by: 2).reduce(0.0) { $0 + abs(Double(pcm[$1])) }
                let right = stride(from: 1, to: pcm.count, by: 2).reduce(0.0) { $0 + abs(Double(pcm[$1])) }
                #expect(right > 0 && left < right * 0.01)
                let route = MIDISessionRoute(input: midi.input, output: nil, sendsLoopNotes: false, channel: 1, clockMode: .off)
                try await model.configureMIDI(route)
                try model.beginMIDILearn(gain)
                await midi.emit(.init(sourceID: midi.input, hostTime: 1, message: .controlChange(channel: 1, controller: 74, value: 64)))
                try await Self.waitUntil("learned CC render") {
                    model.refresh(); return model.overrideGeneration == 2
                }
                #expect(model.learnAddress == nil)
                #expect(model.learnedBindings.first?.address == gain)
                #expect(model.controlValue(try #require(model.controlCatalog?.descriptor(for: gain))) == 128.0 / 127)
                let old = LiveControlAddress(revision: 0, target: .source(0), parameter: .gain)
                let binding = DocumentHostStateStore.LearnBinding(endpoint: midi.input, channel: 1, controller: 74, address: old, range: 0...4)
                let state = DocumentHostStateStore.State(adoptedSourceDigest: DocumentHostStateStore.sourceDigest(source),
                    route: route, effect: nil, effectBypassed: false, bindings: [binding])
                try await model.restoreHostSettings(state, revision: 1)
                #expect(model.learnedBindings.first?.address == gain)
                #expect(model.learnedBindings.first?.range == 0...4)
                let invalid = DocumentHostStateStore.State(adoptedSourceDigest: DocumentHostStateStore.sourceDigest(source),
                    route: route, effect: nil, effectBypassed: false, bindings: [
                        .init(endpoint: midi.input, channel: 1, controller: 74, address: old, range: -1...4)])
                try await model.restoreHostSettings(invalid, revision: 1)
                #expect(model.learnedBindings.isEmpty)
                let stale = DocumentHostStateStore.State(adoptedSourceDigest: DocumentHostStateStore.sourceDigest("different"),
                    route: route, effect: nil, effectBypassed: false, bindings: [binding])
                try await model.restoreHostSettings(stale, revision: 1)
                #expect(model.learnedBindings.isEmpty)
                #expect(model.hostDiagnostic.contains("Stale"))
                let rate = try Self.requireAddress(model, target: .master, parameter: .playbackRate)
                model.bpm = 137
                try model.beginMIDILearn(rate)
                await midi.emit(.init(sourceID: midi.input, hostTime: 2, message: .controlChange(channel: 1, controller: 71, value: 127)))
                try await Self.waitUntil("master CC") { model.displayedBPM == 240 }
                #expect(harness.engine.masterParametersForTests.rate == 2)
                #expect(model.overrideGeneration == 2)
                try model.setControl(rate, value: nil)
                #expect(model.displayedBPM == 137)
                #expect(model.source == source && model.revision == 1)
                try harness.engine.play()
                for gainValue in ["0.7", "0.6"] {
                    model.source = source.replacingOccurrences(of: "0.8", with: gainValue)
                    model.scheduleEvaluation(immediate: true)
                    try await Self.waitUntil("latest candidate prepared", timeout: .seconds(90)) { !model.isPreparing }
                    #expect(model.diagnostic.isEmpty)
                    #expect(model.candidateCatalogs.count == 1)
                    #expect(model.candidateSourceDigests.count == 1)
                    #expect(model.candidateCatalogs.keys.sorted() == model.candidateSourceDigests.keys.sorted())
                    #expect(model.candidateSourceDigests[model.revision] == DocumentHostStateStore.sourceDigest(model.source))
                    #expect(model.currentRevision == 1)
                }
                try await harness.shutdown()
                #expect(await midi.counters().stopped)
            } catch {
                try await harness.shutdown()
                throw error
            }
        }

        @MainActor
        @Test(.timeLimit(.minutes(4)))
        func cancelledDocumentRestoreAndMissingSidecarPreserveHostTransactions() async throws {
            let midi = SessionMIDIService()
            let harness = try Harness(midiService: midi)
            do {
                let model = harness.model
                let engine = harness.engine
                try await Self.adopt(harness, source: Self.baseSource, revision: 1)
                let effect = try #require(engine.discoverAudioEffects().first {
                    $0.id.componentManufacturer == kAudioUnitManufacturer_Apple && $0.id.componentSubType == kAudioUnitSubType_HighPassFilter
                }).id
                try await engine.selectAudioEffect(effect)
                let savedEffect = try engine.captureAudioEffectState()
                try engine.clearAudioEffect()
                let route = MIDISessionRoute(input: midi.input, output: nil, sendsLoopNotes: false, channel: 1, clockMode: .off)
                let document = harness.completionWorkspace.appending(path: "A.swift")
                try Self.baseSource.write(to: document, atomically: true, encoding: .utf8)
                let store = DocumentHostStateStore(directory: harness.completionWorkspace.appending(path: "HostState"))
                try store.save(.init(adoptedSourceDigest: DocumentHostStateStore.sourceDigest(Self.baseSource),
                    route: route, effect: savedEffect, effectBypassed: false, bindings: []), for: document)
                var callback: AudioUnitInstantiation.Completion?
                engine.audioUnitStart = { _, completion in callback = completion }
                try model.openDocument(at: document)
                try engine.play()
                try await Self.waitUntil("delayed document AU restore", timeout: .seconds(90)) {
                    model.refresh(); return callback != nil
                }
                #expect(model.isRestoringHostState)
                let lateCallback = try #require(callback)
                engine.audioUnitStart = AudioUnitInstantiation.nativeStart
                model.source = Self.alternateSource
                model.scheduleEvaluation(immediate: true)
                try await Self.waitUntil("new revision cancels old host restore", timeout: .seconds(90)) {
                    model.refresh(); return model.currentRevision == 3 && model.controlsAvailable && !model.isRestoringHostState
                }
                #expect(model.hostDiagnostic.isEmpty, "Adoption must cancel the restore before its AU deadline.")
                await withCheckedContinuation { continuation in
                    AudioUnitInstantiation.nativeStart(effect.componentDescription) { unit, error in
                        lateCallback(unit, error)
                        continuation.resume()
                    }
                }
                for _ in 0..<100 { await Task.yield() }
                #expect(engine.audioEffectSnapshot() == .none)
                #expect(model.midiRoute == .disabled)
                #expect(model.source == Self.alternateSource)
                #expect(engine.snapshot().revision == 3)
                try await model.configureMIDI(route)
                try await model.selectHostedEffect(effect)
                try engine.play()
                var rejectOnce = true
                engine.audioUnitGraphStartCheck = {
                    if rejectOnce { rejectOnce = false; throw HostedAudioUnitError.graphFailed("Reset failure") }
                }
                let empty = DocumentHostStateStore.State(adoptedSourceDigest: nil, route: .disabled,
                    effect: nil, effectBypassed: false, bindings: [])
                await #expect(throws: (any Error).self) { try await model.restoreHostSettings(empty, revision: 3) }
                #expect(model.midiRoute == route)
                guard case .loaded(let retained, _) = engine.audioEffectSnapshot() else {
                    throw EvaluationError.invalidResult("Failed reset discarded the previous Audio Unit")
                }
                #expect(retained.id == effect)
                engine.audioUnitGraphStartCheck = nil
                engine.stop()
                let other = harness.completionWorkspace.appending(path: "B.swift")
                try Self.alternateSource.write(to: other, atomically: true, encoding: .utf8)
                try model.openDocument(at: other)
                try engine.play()
                try await Self.waitUntil("missing sidecar resets document host", timeout: .seconds(90)) {
                    model.refresh(); return model.currentRevision == 4 && model.controlsAvailable
                        && !model.isRestoringHostState && model.midiRoute == .disabled && engine.audioEffectSnapshot() == .none
                }
                #expect(model.source == Self.alternateSource)
                try await harness.shutdown()
            } catch {
                try await harness.shutdown()
                throw error
            }
        }

        @MainActor
        private static func adopt(_ harness: Harness, source: String, revision: UInt64) async throws {
            harness.model.source = source
            harness.model.scheduleEvaluation(immediate: true)
            try await waitUntil("revision \(revision) adoption", timeout: .seconds(150)) {
                harness.model.refresh()
                if !harness.model.isPreparing, !harness.model.diagnostic.isEmpty {
                    throw EvaluationError.invalidResult(harness.model.diagnostic)
                }
                return harness.model.revision == revision
                    && harness.model.currentRevision == revision
                    && harness.model.loop != nil
                    && harness.model.controlsAvailable
            }
        }

        @MainActor
        private static func render(_ engine: AudioLoopEngine) throws -> [Float] {
            try engine.prepareOfflineRenderingForTests()
            try engine.play()
            let samples = try engine.renderOfflineForTests(frameCount: 4_096)
            engine.stop()
            return samples
        }

        @MainActor
        private static func requireAddress(
            _ model: SessionModel,
            target: LiveControlTarget,
            parameter: LiveControlParameter
        ) throws -> LiveControlAddress {
            guard let address = model.controlCatalog?.descriptors.first(where: {
                $0.address.target == target && $0.address.parameter == parameter
            })?.address else {
                throw EvaluationError.invalidResult("Expected live control address is missing.")
            }
            return address
        }

        @MainActor
        private static func waitUntil(
            _ description: String,
            timeout: Duration = .seconds(30),
            _ predicate: () throws -> Bool
        ) async throws {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while try !predicate(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard try predicate() else {
                throw EvaluationError.timedOut("Timed out while waiting for \(description).")
            }
        }

        private static func energy(_ samples: [Float]) -> Double {
            guard !samples.isEmpty else { return 0 }
            return sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        }

        @MainActor
        private static func withHarness(
            _ body: (Harness) async throws -> Void
        ) async throws {
            let harness = try Harness()
            do {
                try await body(harness)
            } catch {
                do { try await harness.shutdown() }
                catch { Issue.record("Harness shutdown failed after test error: \(error)") }
                throw error
            }
            try await harness.shutdown()
        }

        private static let baseSource = """
        struct Session: Music {
            var body: some Sound {
                Synthesizer(.sine).notes("C4 C4 C4 C4").gain(0.8)
            }
        }
        """

        private static let alternateSource = """
        struct Session: Music {
            var body: some Sound {
                Synthesizer(.sine).notes("D4 E4 D4 E4").gain(0.7)
            }
        }
        """

        private static let recoverySource = """
        struct Session: Music {
            var body: some Sound {
                Synthesizer(.sine).notes("G3 A3 G3 A3").gain(0.6)
            }
        }
        """

        @MainActor
        private final class Harness {
            let evaluator: SourceEvaluator
            let completionService: SwiftCompletionService
            let engine: AudioLoopEngine
            let model: SessionModel
            let evaluatorWorkspace: URL
            let completionWorkspace: URL

            init(midiService: (any MIDIServiceProtocol)? = nil) throws {
                let package = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                evaluatorWorkspace = package.appending(path: ".build/session-model-evaluation")
                completionWorkspace = FileManager.default.temporaryDirectory
                    .appending(path: "SessionModel-Completion-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: evaluatorWorkspace, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: completionWorkspace, withIntermediateDirectories: true)
                evaluator = SourceEvaluator(packageURL: package, workspace: evaluatorWorkspace,
                    swiftExecutable: "/usr/bin/swift")
                completionService = SwiftCompletionService(packageURL: package,
                    workspace: completionWorkspace, sourceKitLSPExecutable: "/usr/bin/sourcekit-lsp")
                engine = try AudioLoopEngine()
                model = SessionModel(evaluator: evaluator, completionService: completionService, engine: engine, midiService: midiService,
                    hostStateStore: DocumentHostStateStore(directory: completionWorkspace.appending(path: "HostState")))
            }

            func shutdown() async throws {
                try await model.shutdown()
                if FileManager.default.fileExists(atPath: evaluatorWorkspace.path) {
                    try FileManager.default.removeItem(at: evaluatorWorkspace)
                }
                if FileManager.default.fileExists(atPath: completionWorkspace.path) {
                    try FileManager.default.removeItem(at: completionWorkspace)
                }
            }
        }
    }
}
