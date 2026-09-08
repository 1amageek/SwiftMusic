import AVFoundation
import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndApp
@testable import MusicPlaygourndCore

actor SessionMIDIService: MIDIServiceProtocol {
    let input = try! MIDIEndpointID(rawValue: 701)
    let output = try! MIDIEndpointID(rawValue: 702)
    var connected = Set<MIDIEndpointID>()
    var selectedOutput: MIDIEndpointID?
    var mode = MIDIClockMode.off
    var health = MIDIClockHealth.unavailable
    var received: MIDIReceivedClockState?
    var scheduledWindows: [ClosedRange<Double>] = []
    var anchors = 0
    var nilAnchors = 0
    var stopped = false
    var failOutput = false
    private let events = AsyncStream<TimestampedMIDIEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))

    func enumerateEndpoints() throws -> [MIDIEndpointDescriptor] {
        [try MIDIEndpointDescriptor(id: input, displayName: "Input", direction: .input, isVirtual: true),
         try MIDIEndpointDescriptor(id: output, displayName: "Output", direction: .output, isVirtual: true)]
    }
    func connectInput(_ id: MIDIEndpointID) { connected.insert(id) }
    func disconnectInput(_ id: MIDIEndpointID) { connected.remove(id) }
    func setOutput(_ id: MIDIEndpointID?) throws {
        if failOutput { failOutput = false; throw MIDIError.coreMIDIStatus(-1) }
        selectedOutput = id
    }
    func eventStream() -> AsyncStream<TimestampedMIDIEvent> { events.stream }
    func emit(_ event: TimestampedMIDIEvent) { events.continuation.yield(event) }
    func updateClockAnchor(_ anchor: PlaybackClockAnchor?) {
        anchors += 1
        if anchor == nil { nilAnchors += 1 }
    }
    func setClockMode(_ mode: MIDIClockMode) { self.mode = mode }
    func send(_ messages: [MIDIScheduledMessage], to id: MIDIEndpointID) {}
    func schedule(loop: PreparedLoop, from startBeat: Double, through endBeat: Double, channel: Int) { scheduledWindows.append(startBeat...endBeat) }
    func windows() -> [ClosedRange<Double>] { scheduledWindows }
    func scheduleClock(from startBeat: Double, through endBeat: Double) {}
    func snapshot() -> MIDIServiceSnapshot {
        MIDIServiceSnapshot(connectedInputIDs: Array(connected), outputID: selectedOutput,
            clockMode: mode, clockHealth: health, receivedClock: received, droppedEventCount: 0)
    }
    func shutdown() { stopped = true; connected.removeAll(); events.continuation.finish() }
    func failNextOutput() { failOutput = true }
    func setHealth(_ health: MIDIClockHealth) { self.health = health }
    func setReceived(_ value: MIDIReceivedClockState) { received = value }
    func counters() -> (anchors: Int, nilAnchors: Int, stopped: Bool) { (anchors, nilAnchors, stopped) }
}

extension NativeHostTests {
    @MainActor struct SessionMIDITests {
        @Test(.timeLimit(.minutes(1))) func routeRollbackWaitingAndShutdownPreserveAudioAndSource() async throws {
            let service = SessionMIDIService()
            let (model, engine) = try harness(service)
            do {
            let source = model.source
            let route = MIDISessionRoute(input: service.input, output: service.output,
                sendsLoopNotes: false, channel: 1, clockMode: .off)
            try await model.configureMIDI(route)
            try engine.play()
            await model.updateMIDI()
            #expect(model.diagnostic.isEmpty)
            #expect(await service.counters().nilAnchors > 0)
            await service.failNextOutput()
            do {
                try await model.configureMIDI(.disabled)
                Issue.record("Expected native route failure")
            } catch let error as MIDIError { #expect(error == .coreMIDIStatus(-1)) }
            #expect(model.midiRoute == route)
            #expect(await service.snapshot().connectedInputIDs == [service.input])
            #expect(engine.snapshot().revision == 1)
            #expect(engine.snapshot().isPlaying)
            await service.setHealth(.disconnected)
            await model.updateMIDI()
            #expect(model.diagnostic.contains("disconnected"))
            model.diagnostic = "Later editor diagnostic"
            await model.updateMIDI()
            #expect(model.diagnostic == "Later editor diagnostic")
            #expect(model.source == source)
            #expect(model.revision == 0)
            try await model.shutdown()
            let before = await service.counters()
            #expect(before.stopped)
            try await Task.sleep(for: .milliseconds(100))
            #expect(await service.counters().anchors == before.anchors)
            #expect(!engine.snapshot().isPlaying)
            } catch {
                try await model.shutdown()
                throw error
            }
        }

        @Test(.timeLimit(.minutes(1))) func receivedStartContinueStopAndTempoDoNotEvaluateSource() async throws {
            let service = SessionMIDIService()
            let (model, engine) = try harness(service)
            do {
            try await model.configureMIDI(MIDISessionRoute(input: service.input, output: nil,
                sendsLoopNotes: false, channel: 1, clockMode: .receive(input: service.input)))
            await service.setReceived(MIDIReceivedClockState(sourceID: service.input, isRunning: true,
                lastCommand: .start, commandGeneration: 1, pulseOrdinal: 24, estimatedBPM: 150))
            await model.updateMIDI()
            #expect(engine.snapshot().isPlaying)
            #expect(model.bpm == 150)
            _ = try engine.renderOfflineForTests(frameCount: 4_096)
            let progressed = engine.snapshot().beatPosition
            #expect(progressed > 0)
            await model.updateMIDI()
            #expect(engine.snapshot().beatPosition == progressed)
            await service.setReceived(MIDIReceivedClockState(sourceID: service.input, isRunning: false,
                lastCommand: .stop, commandGeneration: 2, pulseOrdinal: 24, estimatedBPM: 150))
            await model.updateMIDI()
            #expect(!engine.snapshot().isPlaying)
            await service.setReceived(MIDIReceivedClockState(sourceID: service.input, isRunning: true,
                lastCommand: .continue, commandGeneration: 3, pulseOrdinal: 24, estimatedBPM: 150))
            await model.updateMIDI()
            #expect(engine.snapshot().isPlaying)
            #expect(engine.snapshot().beatPosition == progressed)
            #expect(model.revision == 0)
            #expect(engine.snapshot().revision == 1)
            try await model.shutdown()
            } catch {
                try await model.shutdown()
                throw error
            }
        }

        @Test(.timeLimit(.minutes(1))) func futurePresentationAnchorSchedulesBeatZeroWithoutClamping() async throws {
            let service = SessionMIDIService()
            let (model, _) = try harness(service)
            do {
                try await model.configureMIDI(MIDISessionRoute(input: nil, output: service.output,
                    sendsLoopNotes: true, channel: 1, clockMode: .off))
                let host = AVAudioTime.hostTime(forSeconds: 100)
                let anchor = try PlaybackClockAnchor(presentationHostTime: host,
                    accumulatedBeatPosition: 0, beatsPerMinute: 120, loopBeatCount: 4,
                    revision: 1, overrideGeneration: 0, isPlaying: true)
                await model.updateMIDI(clockAnchor: anchor,
                    hostTime: host - AVAudioTime.hostTime(forSeconds: 0.1))
                #expect(await service.windows() == [0...0.2])
                #expect(model.diagnostic.isEmpty)
                await model.updateMIDI(clockAnchor: anchor,
                    hostTime: host + AVAudioTime.hostTime(forSeconds: 0.1))
                let windows = await service.windows()
                #expect(windows.count == 2)
                #expect(abs(windows[1].lowerBound - 0.2) < 0.000001)
                #expect(abs(windows[1].upperBound - 0.4) < 0.000001)
                try await model.shutdown()
            } catch {
                try await model.shutdown()
                throw error
            }
        }

        private func harness(_ service: any MIDIServiceProtocol) throws -> (SessionModel, AudioLoopEngine) {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let workspace = FileManager.default.temporaryDirectory.appending(path: "SessionMIDI-\(UUID())")
            let toolchain = "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/"
            let evaluator = SourceEvaluator(packageURL: package, workspace: workspace,
                swiftExecutable: toolchain + "swift")
            let completion = SwiftCompletionService(packageURL: package, workspace: workspace.appending(path: "Completion"),
                sourceKitLSPExecutable: toolchain + "sourcekit-lsp")
            let engine = try AudioLoopEngine()
            let loop = try LoopRenderer().render(SoundCompiler().compile(Synthesizer(.sine).notes("C4")),
                bpm: 120, beatsPerBar: 4)
            engine.beginUpdate(revision: 1)
            try engine.submit(loop: loop, revision: 1)
            try engine.prepareOfflineRenderingForTests()
            let model = SessionModel(evaluator: evaluator, completionService: completion, engine: engine,
                midiService: service)
            model.refresh()
            return (model, engine)
        }
    }
}
