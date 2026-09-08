import AVFoundation
import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct EditorTelemetryTests {
    @Test(.timeLimit(.minutes(2)))
    func presentationIncludesAutomationEndpointsAndKeepsTempoRatio() throws {
        let automation = try GainAutomation(.steps(StepAutomation(values: [0, 1], cycle: .whole)), from: 0, to: 8)
        let session = try LoopRenderSession(sound: SoundCompiler().compile(Synthesizer(.sine).gain(automation)),
                                          bpm: 240, beatsPerBar: 4, revision: 7)
        let node = try #require(session.catalog.descriptors.first { if case .renderNode = $0.address.target { return true }; return false })
        let presentation = try #require(node.presentation)
        #expect(presentation.unit == .amplitude)
        #expect(presentation.maximum == 8)
        #expect(try presentation.value(at: 1) == 8)
        let tempo = try LiveControlPresentation.suggested(for: .playbackRate, including: [1])
        #expect(tempo.unit == .ratio)
        #expect(tempo.minimum == 40.0 / 120)
        let cutoff = try LiveControlPresentation.suggested(for: .cutoffHz)
        #expect(abs(try cutoff.value(at: 0.5) - sqrt(20 * 20_000)) < 0.001)
        let baseline = session.baseline.samples
        let visualization = try session.visualization(for: node.address)
        let points = try #require(visualization.traces.first?.channels.first?.points)
        #expect(points.contains { $0.beat == 2 && $0.value == 8 })
        #expect(session.baseline.samples == baseline)
        let replaced = try session.visualization(for: node.address,
            overrides: [.init(address: node.address, value: .number(3))])
        #expect(replaced.traces[0].channels[0].points.allSatisfy { $0.value == 3 })
        #expect(throws: ControlVisualizationError.pointLimit) {
            let dense = try GainAutomation(.steps(StepAutomation(values: [0, 1], cycle: MusicalTime(numerator: 1, denominator: 1_000))), from: 0, to: 1)
            let many = try LoopRenderSession(sound: SoundCompiler().compile(Synthesizer(.sine).gain(dense)), bpm: 240, beatsPerBar: 4)
            let target = try #require(many.catalog.descriptors.last)
            _ = try many.visualization(for: target.address)
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func polyphonicTrajectoriesRetainExactEnvelopeBoundariesAndOverrides() throws {
        let envelope = try Envelope(attack: .milliseconds(100), decay: .milliseconds(100), sustainLevel: 0.5, release: .milliseconds(100))
        let sound = try SoundCompiler().compile(Synthesizer(.sine).notes("C4,E4").gate(0.5)
            .envelope(envelope).pitchEnvelope(envelope, depth: Semitones(value: 12)))
        let session = try LoopRenderSession(sound: sound, bpm: 120, beatsPerBar: 4, revision: 9)
        let address = try #require(session.catalog.descriptors.first { $0.address.parameter == .pitchOffsetSemitones }?.address)
        let result = try session.visualization(for: address)
        #expect(result.traces.count == 2)
        #expect(result.traces.map(\.eventIndex) == [0, 1])
        for (trace, note) in zip(result.traces, [60.0, 64.0]) {
            let selected = try #require(trace.channels.first { $0.kind == .selectedValue })
            let amplitude = try #require(trace.channels.first { $0.kind == .amplitudeEnvelope })
            #expect(selected.points.first?.value == note)
            #expect(selected.points.contains { abs($0.beat - 0.2) < 1e-9 && abs($0.value - note - 12) < 1e-9 })
            #expect(amplitude.points.contains { abs($0.beat - 0.2) < 1e-9 && $0.value == 1 })
            #expect(amplitude.points.last?.value == 0)
        }
        let changed = try session.visualization(for: address, overrides: [.init(address: address, value: .number(12))])
        #expect(changed.traces[0].channels[0].points.first?.value == 72)
        #expect(throws: LiveControlError.self) {
            _ = try session.visualization(for: .init(revision: 8, target: address.target, parameter: address.parameter))
        }
        let encoded = try PropertyListEncoder().encode(result)
        #expect(encoded.count < 1_048_576)
        #expect(try PropertyListDecoder().decode(PreparedControlVisualization.self, from: encoded) == result)
    }

    @Test(.timeLimit(.minutes(1)))
    func wrappedVoiceKeepsUnwrappedEnvelopePhase() throws {
        let notes: NotePattern = "C4"
        let envelope = try Envelope(attack: .milliseconds(500), decay: .zero,
                                    sustainLevel: 1, release: .milliseconds(500))
        let compiled = try SoundCompiler().compile(
            Synthesizer(.sine).notes(notes.phase(.quarter)).gate(0.5).envelope(envelope),
            liveLoop: LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole))
        let session = try LoopRenderSession(sound: compiled, bpm: 120, beatsPerBar: 4)
        let address = try #require(session.catalog.descriptors.first { $0.address.parameter == .gain }?.address)
        let trace = try #require(session.visualization(for: address).traces.first)
        #expect(trace.startBeat == 3)
        #expect(trace.wrapsLoopBoundary)
        let amplitude = try #require(trace.channels.first { $0.kind == .amplitudeEnvelope })
        #expect(amplitude.points.first?.value == 0)
        #expect(amplitude.points.contains { $0.beat == 4 && $0.value == 1 })
        #expect(amplitude.points.last?.beat == 6)
        #expect(amplitude.points.last?.value == 0)
    }

    @Test(.timeLimit(.minutes(2)))
    func metersUseTrackAndBusBoundariesAndRefreshWithOverrides() throws {
        struct Mix: Sound {
            var body: some Sound {
                Track("Lead") { Synthesizer(.sine).notes("C4") }
                    .trackLevel(10).send(to: "room", level: 0.5, placement: .postFader)
                BusReturn("room").gain(0)
            }
        }
        let session = try LoopRenderSession(sound: SoundCompiler().compile(Mix()), bpm: 240, beatsPerBar: 4, revision: 1)
        let meters = try #require(session.baseline.meters)
        let track = try #require(meters.first { $0.target == .track(0) })
        let bus = try #require(meters.first { $0.target == .bus("room") })
        #expect(track.peaks.max() ?? 0 > 1)
        #expect(track.clipFlags.contains(true))
        #expect(zip(track.peaks, bus.peaks).allSatisfy { abs($0 * 0.5 - $1) < 0.00001 })
        #expect(session.baseline.samples.allSatisfy { abs($0) <= 1 })
        let address = try #require(session.catalog.descriptors.first { $0.address.parameter == .trackLevel }?.address)
        let muted = try session.render(overrides: [.init(address: address, value: .number(0))])
        #expect(muted.meters?.allSatisfy { $0.peaks.allSatisfy { $0 == 0 } } == true)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session.baseline)) as? [String: Any])
        legacy.removeValue(forKey: "meters")
        let decoded = try JSONDecoder().decode(PreparedLoop.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.meters == nil)
        try decoded.validate()
    }

    @Test(.timeLimit(.minutes(1)))
    func visualizationRejectsMalformedAndOversizedTraces() throws {
        let address = LiveControlAddress(revision: 1, target: .source(0), parameter: .gain)
        let points = [PreparedControlTrace.Channel.Point(beat: 0, value: 1), .init(beat: 1, value: 0)]
        func trace(_ index: Int, points: [PreparedControlTrace.Channel.Point]) -> PreparedControlTrace {
            .init(eventIndex: index, sourceID: 0, startBeat: 0, durationBeats: 1,
                  wrapsLoopBoundary: false, channels: [.init(kind: .selectedValue, points: points)])
        }
        #expect(throws: ControlVisualizationError.invalidData) {
            _ = try PreparedControlVisualization(address: address, unit: .amplitude, beatCount: 4,
                traces: [trace(0, points: points), trace(0, points: points)])
        }
        #expect(throws: ControlVisualizationError.invalidData) {
            _ = try PreparedControlVisualization(address: address, unit: .amplitude, beatCount: 4,
                traces: [trace(0, points: [.init(beat: 0, value: .nan), points[1]])])
        }
        let dense = (0..<512).map { PreparedControlTrace.Channel.Point(beat: Double($0) / 511, value: 1) }
        #expect(throws: ControlVisualizationError.pointLimit) {
            _ = try PreparedControlVisualization(address: address, unit: .amplitude, beatCount: 4,
                traces: (0..<33).map { trace($0, points: dense) })
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func telemetryRejectsInvalidCatalogUnitsChannelsAndIdentities() throws {
        let address = LiveControlAddress(revision: 1, target: .renderNode(0), parameter: .gain)
        let points = [PreparedControlTrace.Channel.Point(beat: 0, value: 1), .init(beat: 4, value: 1)]
        let channelSets: [[PreparedControlTrace.Channel.Kind]] = [[.amplitudeEnvelope], [.selectedValue, .amplitudeEnvelope]]
        for kinds in channelSets {
            #expect(throws: ControlVisualizationError.invalidData) {
                _ = try PreparedControlVisualization(address: address, unit: .amplitude, beatCount: 4,
                    traces: [.init(eventIndex: nil, sourceID: nil, startBeat: 0, durationBeats: 4,
                        wrapsLoopBoundary: false, channels: kinds.map { .init(kind: $0, points: points) })])
            }
        }
        for presentation in [
            try LiveControlPresentation(unit: .hertz, minimum: 20, maximum: 20_000, scale: .logarithmic),
            try LiveControlPresentation(unit: .amplitude, minimum: 0, maximum: 1),
            try LiveControlPresentation(unit: .amplitude, minimum: 0, maximum: 2)
        ] {
            #expect(throws: LiveControlError.self) {
                _ = try LiveControlCatalog(descriptors: [.init(address: address, label: "Gain",
                    baseline: .scalar(3), presentation: presentation)])
            }
        }
        _ = try LiveControlCatalog(descriptors: [.init(address: address, label: "Legacy", baseline: .scalar(3))])
        for target in [PreparedMeterEnvelope.Target.track(32), .bus(" \n")] {
            #expect(throws: PreparedLoopValidationError.self) {
                try PreparedMeterEnvelope(target: target, label: "Invalid", peaks: [1]).validate()
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func monoTapPublishesPeakAndMirrorsStereoViewport(interleaved: Bool) throws {
        let store = OutputMeterStore()
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000, channels: 1, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let samples = try #require(buffer.floatChannelData?[0])
        samples[0] = 1.25; samples[1] = 0.5; samples[2] = -0.25; samples[3] = 0
        store.activate()
        store.capture(buffer, at: AVAudioTime(sampleTime: 0, atRate: 48_000))
        let snapshot = store.snapshot()
        #expect(snapshot.performance?.peak == 1.25)
        #expect(snapshot.performance?.clipped == true)
        #expect(Array(snapshot.interleavedSamples.prefix(8)) == [1.25, 1.25, 0.5, 0.5, -0.25, -0.25, 0, 0])
        buffer.frameLength = 0
        store.capture(buffer)
        #expect(store.snapshot().performance?.peak == nil)
        #expect(store.snapshot().performance?.clipped == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func meterTelemetryCoversFullTapAndFreezesUntilExplicitReset() throws {
        let store = OutputMeterStore()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            buffer.floatChannelData![channel].initialize(repeating: 0.1, count: 4_096)
        }
        buffer.floatChannelData![0][0] = 1.25
        store.activate()
        store.recordCallback(elapsed: 0.001, duration: 0.01, failed: false)
        store.capture(buffer, at: AVAudioTime(sampleTime: 0, atRate: 48_000))
        let initial = try #require(store.snapshot().performance)
        #expect(initial.callbackLoad == 0.1)
        #expect(initial.peak == 1.25)
        #expect(initial.clipped)
        #expect(store.snapshot().interleavedSamples.max() == 0.1)
        store.recordCallback(elapsed: 0.02, duration: 0.01, failed: false)
        store.capture(buffer, at: AVAudioTime(sampleTime: 4_100, atRate: 48_000))
        let late = try #require(store.snapshot().performance)
        #expect(late.dropoutCount == 2)
        store.clear()
        store.recordCallback(elapsed: 0, duration: 1, failed: false)
        #expect(store.snapshot().performance == late)
        store.activate()
        #expect(store.snapshot().performance == late)
        store.resetDiagnostics()
        #expect(store.snapshot().performance?.dropoutCount == 0)
        #expect(store.snapshot().performance?.callbackLoad == nil)
        #expect(store.snapshot().performance?.clipped == false)
    }
}

extension NativeHostTests {
    struct NativeTelemetryTests {
        @MainActor @Test(.timeLimit(.minutes(1)))
        func hardwareCallbackPublishesPerformanceAndFreezesOnStop() async throws {
            let loop = try LoopRenderer().render(SoundCompiler().compile(Synthesizer(.sine).gain(0.001)), bpm: 120, beatsPerBar: 4)
            let engine = try AudioLoopEngine()
            defer { engine.stop() }
            engine.beginUpdate(revision: 7)
            try engine.submit(loop: loop, revision: 7)
            try engine.play()
            try await Task.sleep(for: .milliseconds(250))
            let performance = try #require(engine.outputMeter().performance)
            #expect(try #require(performance.callbackLoad) >= 0)
            #expect(try #require(performance.peak) > 0)
            engine.stop()
            let stopped = engine.outputMeter().performance
            try await Task.sleep(for: .milliseconds(50))
            #expect(engine.outputMeter().performance == stopped)
        }
    }
}
