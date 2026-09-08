import AVFoundation
import Darwin
import Foundation
import Testing
import SwiftMusic
import SwiftUI
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
        @Test(.timeLimit(.minutes(6)))
        func atomicXYAndLearnRestoreRetainSourceAndPCM() async throws {
            let midi = SessionMIDIService()
            let harness = try Harness(midiService: midi)
            do {
                try await Self.adopt(harness, source: Self.baseSource, revision: 1)
                let model = harness.model
                let source = model.source
                let gain = try Self.requireAddress(model, target: .source(0), parameter: .gain)
                let pan = try Self.requireAddress(model, target: .source(0), parameter: .pan)
                let unsupported = LiveControlAddress(
                    revision: model.revision,
                    target: .source(0),
                    parameter: .cutoffHz
                )
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
                let unchangedLoop = try #require(model.loop)
                model.selectedControl = unsupported
                try await Self.waitForUnavailable(model, description: "unsupported selection keeps controls")
                #expect(model.controlsAvailable && model.controlVisualization == nil)
                #expect(model.loop == unchangedLoop && model.overrideGeneration == 1)
                model.selectedControl = gain
                try await Self.waitUntil("selected gain trajectories") {
                    model.controlVisualization?.address == gain
                }
                #expect(model.controlVisualization?.traces.isEmpty == false)
                #expect(model.loop == unchangedLoop && model.overrideGeneration == 1)
                #expect(model.source == source)
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

                let retainedVisualizationLoop = try #require(model.loop)
                let retainedVisualizationCatalog = try #require(model.controlCatalog)
                let retainedVisualizationSource = model.source
                let retainedVisualizationRevision = model.revision
                let retainedVisualizationGeneration = model.overrideGeneration
                let workerPID = try #require(await harness.evaluator.workerStateForTests().pid)
                model.selectedControl = unsupported
                try await Self.waitForUnavailable(model, description: "prepare stopped visualization")
                try Self.signal(SIGSTOP, to: workerPID)
                var workerStopped = true
                defer {
                    if workerStopped { _ = Darwin.kill(workerPID, SIGCONT) }
                }

                model.selectedControl = gain
                await Task.yield()
                try await Self.waitUntil("stopped worker pending visualization") {
                    model.visualizationStatus.contains("Loading")
                }
                model.selectedControl = unsupported
                await Task.yield()
                try Self.signal(SIGCONT, to: workerPID)
                workerStopped = false
                try await Self.waitForUnavailable(model, description: "resumed visualization cancellation")
                #expect(model.controlsAvailable)
                #expect(model.controlVisualization == nil)
                let afterCancellationLoop = model.loop.map { $0 == retainedVisualizationLoop } ?? false
                #expect(afterCancellationLoop)
                #expect(model.controlCatalog == retainedVisualizationCatalog)
                #expect(model.source == retainedVisualizationSource)
                #expect(model.revision == retainedVisualizationRevision)
                #expect(model.overrideGeneration == retainedVisualizationGeneration)

                model.selectedControl = gain
                await Task.yield()
                try await Self.waitUntil("resumed gain visualization") {
                    model.refresh()
                    return model.controlVisualization?.address == gain
                }
                let pcmAfterCancellation = try Self.render(harness.engine)
                #expect(Self.energy(pcmAfterCancellation) > 0.0001)

                model.selectedControl = unsupported
                try await Self.waitForUnavailable(model, description: "prepare override visualization")
                try Self.signal(SIGSTOP, to: workerPID)
                workerStopped = true
                model.selectedControl = gain
                await Task.yield()
                try await Self.waitUntil("override visualization pending") {
                    model.visualizationStatus.contains("Loading")
                }
                let nextOverrideGeneration = model.overrideGeneration + 1
                try model.setControl(gain, value: .number(0.25))
                try Self.signal(SIGCONT, to: workerPID)
                workerStopped = false
                try await Self.waitUntil("override adoption after visualization") {
                    model.refresh()
                    return model.overrideGeneration == nextOverrideGeneration
                }
                let retainedOverrideLoop = try #require(model.loop)
                let retainedOverrideCatalog = try #require(model.controlCatalog)
                let retainedOverrideSource = model.source
                let retainedOverrideRevision = model.revision
                let retainedOverrideGeneration = model.overrideGeneration

                try await Self.waitUntil("automatically adopted override visualization") {
                    model.refresh()
                    return model.controlVisualization?.address == gain
                }
                let selectedValues = model.controlVisualization?.traces.flatMap { trace in
                    trace.channels.filter { $0.kind == .selectedValue }.flatMap(\.points)
                }.map(\.value) ?? []
                let selectedValuesUseNewOverride = !selectedValues.isEmpty
                    && selectedValues.allSatisfy { abs($0 - 0.25) < 0.0001 }
                #expect(selectedValuesUseNewOverride)
                #expect(model.loop == retainedOverrideLoop)
                #expect(model.controlCatalog == retainedOverrideCatalog)
                #expect(model.source == retainedOverrideSource)
                #expect(model.revision == retainedOverrideRevision)
                #expect(model.overrideGeneration == retainedOverrideGeneration)

                try Self.signal(SIGKILL, to: workerPID)
                model.selectedControl = unsupported
                await Task.yield()
                try await Self.waitForUnavailable(model, description: "fatal visualization retains session")
                try await Self.waitUntil("fatal visualization marks worker unavailable") {
                    model.refresh()
                    return !model.controlsAvailable
                }
                #expect(model.controlVisualization == nil)
                let afterFailureLoop = model.loop.map { $0 == retainedOverrideLoop } ?? false
                #expect(afterFailureLoop)
                #expect(model.controlCatalog == retainedOverrideCatalog)
                #expect(model.source == retainedOverrideSource)
                #expect(model.revision == retainedOverrideRevision)
                #expect(model.overrideGeneration == retainedOverrideGeneration)
                let pcmAfterFailure = try Self.render(harness.engine)
                #expect(Self.energy(pcmAfterFailure) > 0.0001)
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
                let untitledID = model.activeDocumentID
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
                model.source = Self.alternateSource
                try model.openDocument(at: document)
                try engine.play()
                try await Self.waitUntil("delayed document AU restore", timeout: .seconds(90)) {
                    model.refresh(); return callback != nil
                }
                #expect(model.isRestoringHostState)
                let lateCallback = try #require(callback)
                engine.audioUnitStart = AudioUnitInstantiation.nativeStart
                model.selectDocument(untitledID)
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
        @Test(.timeLimit(.minutes(6)))
        func performanceControlsCommitAfterAudibleFadeAndKeepEditorState() async throws {
            try await Self.withHarness { harness in
                let model = harness.model
                try await Self.adopt(harness, source: Self.performanceSource, revision: 1)
                let originalSource = model.source
                let originalRevision = model.revision
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                    styleMask: [.titled], backing: .buffered, defer: false)
                let host = NSHostingView(rootView: PerformanceEditorFixture(model: model))
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let editor = try #require(Self.findEditor(in: host))
                window.makeFirstResponder(editor)
                editor.insertText(" ", replacementRange: NSRange(location: originalSource.utf16.count, length: 0))
                let undo = try #require(editor.undoManager)
                undo.undo()
                #expect(editor.string == originalSource)
                #expect(undo.canRedo)
                (editor.delegate as? CodeEditor.Coordinator)?.cancelCompletion()
                let selection = NSRange(location: 0, length: 0)
                editor.setSelectedRange(selection)
                let completion = SwiftCompletion(label: "Comment", detail: nil, insertion: "// retained\n",
                    replacementRange: selection)
                editor.presentCompletions([completion], source: originalSource, selection: selection)
                model.completionStatus = "Completion retained"
                defer { editor.dismissCompletions(); window.contentView = nil }
                #expect(model.performanceControlMetadata.map(\.controlID) == ["gain", "tempo", "position"])
                #expect(model.performanceNumber("tempo") == 90)
                #expect(model.controlCatalog?.descriptors.contains { $0.address.parameter == .playbackRate } == false)

                let gainAddress = try Self.requireAddress(model, target: .source(0), parameter: .gain)
                try model.setControl(gainAddress, value: .number(-1))
                try await Self.waitUntil("rejected score generation") { !model.diagnostic.isEmpty }
                model.diagnostic = ""
                try harness.engine.prepareOfflineRenderingForTests()
                try harness.engine.play()
                _ = try harness.engine.renderOfflineForTests(frameCount: 4096)
                var release: CheckedContinuation<Void, Never>?
                model.performanceReservationDidPrepare = {
                    await withCheckedContinuation { release = $0 }
                }
                defer { release?.resume(); model.performanceReservationDidPrepare = nil }
                try model.setPerformanceValue("gain", value: .double(0.4))
                try await Self.waitUntil("first performance reservation") { release != nil }
                try model.setPerformanceValue("tempo", value: .double(100))
                try model.setPerformancePosition("position", x: 0.5)
                try model.setPerformancePosition("position", depth: 0.5)
                model.performanceReservationDidPrepare = nil
                release?.resume()
                release = nil
                try await Self.waitUntil("performance generation confirmation", timeout: .seconds(240)) {
                    let samples = try harness.engine.renderOfflineForTests(frameCount: 256)
                    #expect(samples.allSatisfy { $0.isFinite })
                    if harness.engine.snapshot().performanceGeneration == 0 {
                        #expect(model.performanceNumber("tempo") == 90)
                    }
                    model.refresh()
                    return harness.engine.snapshot().performanceGeneration > 0
                        && model.performanceNumber("gain") == 0.4
                        && model.performanceNumber("tempo") == 100
                        && model.performancePosition("position") == .init(x: 0.5, depth: 0.5)
                        && !model.isPerformanceUpdating
                }
                #expect(model.source == originalSource)
                #expect(model.revision == originalRevision)
                #expect(model.currentRevision == originalRevision)
                host.layoutSubtreeIfNeeded()
                #expect(Self.findEditor(in: host) === editor)
                #expect(editor.selectedRange() == selection)
                #expect(undo.canRedo)
                #expect(model.completionStatus == "Completion retained")
                editor.acceptSelectedCompletion()
                #expect(editor.string == "// retained\n" + originalSource)
                undo.undo()
                #expect(editor.string == originalSource)
                #expect(model.source == originalSource)
                #expect(model.loop?.bpm == 100)
                #expect(model.loop?.rows.count == 2)
                #expect(model.resultLines.count == 2)
                #expect(model.loop?.samples.contains { abs($0) > 0.001 } == true)
                #expect(abs(harness.engine.masterParametersForTests.rate - 1) < 0.00001)
                #expect(model.diagnostic.isEmpty)
                let nextGain = try Self.requireAddress(model, target: .source(0), parameter: .gain)
                try model.setControl(nextGain, value: .number(0.15))
                try await Self.waitUntil("score generation remains monotonic after graph change") {
                    _ = try harness.engine.renderOfflineForTests(frameCount: 4096)
                    model.refresh()
                    if !model.diagnostic.isEmpty { throw EvaluationError.invalidResult(model.diagnostic) }
                    return model.overrideGeneration == 2
                }
                try model.setControl(nextGain, value: nil)
                try await Self.waitUntil("score override release") {
                    _ = try harness.engine.renderOfflineForTests(frameCount: 4096)
                    model.refresh()
                    return model.overrideGeneration == 3
                }
                let accepted = model.loop
                try model.setPerformanceValue("gain", value: .double(0.9))
                try await Self.waitUntil("invalid performance body rollback", timeout: .seconds(30)) {
                    _ = try harness.engine.renderOfflineForTests(frameCount: 256)
                    model.refresh()
                    return !model.isPerformanceUpdating && !model.diagnostic.isEmpty
                }
                #expect(model.loop == accepted)
                #expect(model.performanceNumber("gain") == 0.4)
                #expect(model.controlsAvailable)
                #expect(model.source == originalSource)
            }
        }

        @MainActor
        @Test(.timeLimit(.minutes(6)))
        func performanceCompositionRetainsScoreOverlaysAndRestoresIndependentTempo() async throws {
            try await Self.withHarness { harness in
                let model = harness.model
                model.bpm = 137
                try await Self.adopt(harness, source: Self.performanceSource, revision: 1)
                #expect(model.displayedBPM == 90)
                #expect(abs(harness.engine.masterParametersForTests.rate - 1) < 0.00001)
                try harness.engine.prepareOfflineRenderingForTests()
                try harness.engine.play()
                try model.setPerformanceValue("gain", value: .double(0.4))
                try await Self.waitUntil("performance with second source") {
                    _ = try harness.engine.renderOfflineForTests(frameCount: 4096)
                    model.refresh()
                    return model.performanceNumber("gain") == 0.4 && !model.isPerformanceUpdating
                }
                let gain = try Self.requireAddress(model, target: .source(0), parameter: .gain)
                try model.setControl(gain, value: .number(0))
                try await Self.waitUntil("muted source overlay") {
                    _ = try harness.engine.renderOfflineForTests(frameCount: 4096)
                    model.refresh()
                    return model.overrideGeneration == 1
                }
                let muted = try #require(model.loop).samples
                try model.setPerformanceValue("gain", value: .double(0.5))
                try await Self.waitUntil("model update with score overlay") {
                    _ = try harness.engine.renderOfflineForTests(frameCount: 4096)
                    model.refresh()
                    if !model.diagnostic.isEmpty { throw EvaluationError.invalidResult(model.diagnostic) }
                    return model.performanceNumber("gain") == 0.5 && !model.isPerformanceUpdating
                }
                #expect(model.overrideGeneration == 1)
                #expect(model.loop?.samples == muted)
                try model.setControl(gain, value: nil)
                try await Self.waitUntil("released overlay uses new model baseline") {
                    _ = try harness.engine.renderOfflineForTests(frameCount: 4096)
                    model.refresh()
                    return model.overrideGeneration == 2
                }
                let released = try #require(model.loop).samples
                #expect(Self.energy(released) > Self.energy(muted))
                model.source = Self.baseSource
                model.scheduleEvaluation(immediate: true)
                try await Self.waitUntil("ordinary Music restores independent tempo", timeout: .seconds(260)) {
                    _ = try harness.engine.renderOfflineForTests(frameCount: 4096)
                    model.refresh()
                    if !model.isPreparing, !model.diagnostic.isEmpty { throw EvaluationError.invalidResult(model.diagnostic) }
                    return model.currentRevision == 2 && model.controlsAvailable
                        && model.performanceControlMetadata.isEmpty
                        && abs(harness.engine.masterParametersForTests.rate - Float(137.0 / 120)) < 0.00001
                }
                #expect(model.displayedBPM == 137)
                #expect(harness.engine.snapshot().performanceGeneration == 0)
                #expect(model.controlCatalog?.descriptors.contains { $0.address.parameter == .playbackRate } == true)
            }
        }

        @MainActor
        @Test(.timeLimit(.minutes(6)))
        func documentSwitchDiscardsReservedPerformanceBeforeWorkerAcknowledgement() async throws {
            try await Self.withHarness { harness in
                let model = harness.model
                try await Self.adopt(harness, source: Self.performanceSource, revision: 1)
                try harness.engine.prepareOfflineRenderingForTests()
                try harness.engine.play()
                try model.setPerformanceValue("gain", value: .double(0.4))
                try await Self.waitUntil("initial performance confirmation", timeout: .seconds(30)) {
                    _ = try harness.engine.renderOfflineForTests(frameCount: 4096)
                    model.refresh()
                    return model.performanceNumber("gain") == 0.4 && !model.isPerformanceUpdating
                }
                var release: CheckedContinuation<Void, Never>?
                model.performanceReservationDidPrepare = {
                    await withCheckedContinuation { release = $0 }
                }
                defer { release?.resume(); model.performanceReservationDidPrepare = nil }
                try model.setPerformanceValue("gain", value: .double(0.5))
                try await Self.waitUntil("reserved performance", timeout: .seconds(30)) { release != nil }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
                let document = directory.appendingPathComponent("Session.swift")
                try Self.performanceSource.write(to: document, atomically: true, encoding: .utf8)
                try model.openDocument(at: document)
                release?.resume()
                release = nil
                model.performanceReservationDidPrepare = nil
                try await Self.waitUntil("new document worker", timeout: .seconds(260)) {
                    _ = try harness.engine.renderOfflineForTests(frameCount: 4096)
                    model.refresh()
                    return model.currentRevision == 2 && model.controlsAvailable
                }
                #expect(model.performanceNumber("gain") == 0.2)
                #expect(model.performanceNumber("tempo") == 90)
                #expect(harness.engine.snapshot().performanceGeneration == 0)
                #expect(model.fileURL == document)
                #expect(model.diagnostic.isEmpty)
            }
        }

        @MainActor
        private struct PerformanceEditorFixture: View {
            @Bindable var model: SessionModel
            var body: some View {
                CodeEditor(text: $model.source, inlineLoop: model.loop, inlineEnabled: true,
                    resultLines: model.resultLines, beatPosition: model.beatPosition, isPlaying: model.isPlaying,
                    selectionLine: nil, selectionToken: 0, rhythmLines: [], rowLines: model.rowLines,
                    patternTexts: [:], activeTokens: model.activeTokens, scrollDelta: 0,
                    onLayout: { _ in }, beforeEdit: model.beforeEdit, onEdit: {},
                    completions: { _, _ in [] }, onCompletionStatus: { model.completionStatus = $0 })
            }
        }

        @MainActor
        private static func findEditor(in view: NSView) -> CompletionTextView? {
            if let editor = view as? CompletionTextView { return editor }
            for child in view.subviews {
                if let editor = findEditor(in: child) { return editor }
            }
            return nil
        }

        @MainActor
        private static func adopt(_ harness: Harness, source: String, revision: UInt64) async throws {
            harness.model.source = source
            harness.model.scheduleEvaluation(immediate: true)
            try await waitUntil("revision \(revision) adoption", timeout: .seconds(260)) {
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

        @MainActor
        private static func waitForUnavailable(
            _ model: SessionModel,
            description: String
        ) async throws {
            do {
                try await waitUntil(description) {
                    model.refresh()
                    return model.visualizationStatus.contains("unavailable")
                }
            } catch {
                throw EvaluationError.timedOut(
                    "\(description): status=\(model.visualizationStatus), "
                        + "selected=\(String(describing: model.selectedControl)), "
                        + "controlsAvailable=\(model.controlsAvailable), "
                        + "overrideGeneration=\(model.overrideGeneration)"
                )
            }
        }

        private static func energy(_ samples: [Float]) -> Double {
            guard !samples.isEmpty else { return 0 }
            return sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        }

        @MainActor
        private static func signal(_ signal: Int32, to pid: pid_t) throws {
            guard Darwin.kill(pid, signal) == 0 else {
                throw EvaluationError.processFailed("Unable to send signal \(signal) to worker \(pid).")
            }
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

        private static let performanceSource = """
        import Observation

        @MainActor @Observable
        final class PerformanceState: PerformanceControllable {
            let performanceModelID = "session-model-performance"
            var gain = 0.2
            var tempo = 90.0
            var position = SpatialPosition(x: -0.5, depth: 0)
            var performanceControls: PerformanceControlSet<PerformanceState> {
                get throws {
                    try PerformanceControlSet([
                        .mappedDouble(id: "gain", range: 0...1, keyPath: \\PerformanceState.gain),
                        .mappedBPM(id: "tempo", range: 60...180, keyPath: \\PerformanceState.tempo),
                        .mappedPosition(id: "position", keyPath: \\PerformanceState.position)
                    ])
                }
            }
        }

        struct Session: PerformanceEntry {
            @Performance(PerformanceState.self) private var state
            @MainActor static func makePerformanceModel() -> PerformanceState { PerformanceState() }
            var body: some Sound {
                Synthesizer(.sine).notes("C4").gain(state.gain).position(state.position)
                if state.gain > 0.3 {
                    Synthesizer(.sine).notes("G4").gain(0.1)
                }
                if state.gain > 0.8 {
                    Synthesizer(.sine).notes("E4").gain("oops")
                }
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
