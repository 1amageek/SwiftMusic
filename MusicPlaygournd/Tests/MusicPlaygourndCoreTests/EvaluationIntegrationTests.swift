import AVFoundation
import SwiftMusic
import Foundation
import MusicPlaygourndCore
import Testing

extension NativeHostTests {
    struct EvaluationIntegrationTests {
        @MainActor
        @Test(.timeLimit(.minutes(3)))
        func testEvaluatedRootedBankDSPVoicePolicyReachesNativePlaybackAndFailureRetainsRevision() async throws {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let evaluator = SourceEvaluator(packageURL: package,
                workspace: package.appending(path: ".build/evaluator-integration"), swiftExecutable: "/usr/bin/swift")
            let url = FileManager.default.temporaryDirectory.appending(path: "EvaluatedSample-\(UUID().uuidString).wav")
            defer {
                do { try FileManager.default.removeItem(at: url) }
                catch { Issue.record(error) }
            }
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
            buffer.frameLength = buffer.frameCapacity
            let data = try #require(buffer.floatChannelData)
            for frame in 0..<44_100 { data[0][frame] = Float(sin(2 * Double.pi * 440 * Double(frame) / 44_100)) * 0.3 }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            file.close()
            let source = """
            struct Session: Music {
                let bank: SampleBank
                let envelope: Envelope
                let tuning: Tuning
                let depth: Semitones
                let duckDepth: Decibels
                let compressor: SidechainCompressor
                let limiter: Limiter
                let swing: Swing
                let glide: Portamento
                let arpeggio: Arpeggio
                init() throws {
                    let url = URL(fileURLWithPath: \(url.path.debugDescription))
                    bank = try SampleBank([
                        SampleAsset(key: "a", fileURL: url),
                        SampleAsset(key: "b", fileURL: url, rootPitch: Pitch(midiNote: 72))
                    ])
                    envelope = try Envelope(attack: .milliseconds(1), decay: .milliseconds(10),
                        sustainLevel: 0.8, release: .milliseconds(50))
                    tuning = try Tuning(referencePitch: Pitch(midiNote: 69), frequencyHz: 442)
                    depth = try Semitones(value: 1)
                    duckDepth = try Decibels(value: -6)
                    compressor = try SidechainCompressor(threshold: Decibels(value: -24), ratio: 2,
                        attack: .milliseconds(1), release: .milliseconds(20),
                        knee: Decibels(value: 6), sidechainBus: "room")
                    limiter = try Limiter(ceiling: Decibels(value: -1), release: .milliseconds(10))
                    swing = try Swing(subdivision: .quarter, delay: .sixteenth)
                    glide = try Portamento(duration: .seconds(.milliseconds(100)))
                    arpeggio = try Arpeggio(order: .up, step: .sixteenth)
                }
                var body: some Sound {
                    Track("Bank voices") {
                        Sample(bank: bank)
                            .notes("C4 D4 C4 D4")
                            .sampleSelection("<a b>")
                            .transpose(PitchPattern("0.5 -0.5"))
                            .tuning(tuning)
                            .pitchEnvelope(envelope, depth: depth)
                            .lowPass("800 1600")
                            .gate(1.2)
                            .envelope(envelope)
                            .voicePolicy(.monophonic)
                            .duck(targetBus: "room", depth: duckDepth, attack: .milliseconds(2), recovery: .milliseconds(100))
                            .swing(swing)
                            .chord(.power)
                            .arpeggiated(arpeggio)
                            .legato()
                            .portamento(glide)
                            .tremolo(rate: .synchronized(period: .whole), depth: 0.2)
                            .vibrato(rate: .synchronized(period: .whole), depth: depth)
                    }
                    .trackLevel(0.8)
                    .trackPan(-0.25)
                    .send(to: "room", level: 0.2, placement: .preFader)
                    .effect(.equalizer(frequencyHz: 1_200, gainDecibels: 3, q: 0.7))
                    .effect(.saturation(drive: 0.3))
                    .effect(.delay(time: .quarter, feedback: 0.2, wet: 0.1))
                    .effect(.reverb(roomSize: 0.2, wet: 0.15))
                    BusReturn("room")
                        .effect(.sidechainCompressor(compressor))
                        .effect(.reverb(roomSize: 0.1, wet: 1))
                        .effect(.limiter(limiter))
                        .effect(.filter(kind: .notch, cutoffHz: 2_000, resonance: 0.5))
                        .effect(.chorus(rateHz: 0.5, depth: 0.25, wet: 0.1))
                        .effect(.flanger(rateHz: 0.5, delaySeconds: 0.005, depthSeconds: 0.001, feedback: 0.2, wet: 0.1))
                        .effect(.phaser(rateHz: 0.5, minimumHz: 100, maximumHz: 2_000, stages: 2, feedback: 0.1, wet: 0.1))
                        .effect(.stereoWidth(0.8))
                        .gain(0.9)
                }
            }
            """
            do {
                let evaluated = try await evaluator.evaluateRetained(source: source, bpm: 120, beatsPerBar: 4, revision: 51)
                #expect(await evaluator.adopt(revision: 51))
                let loop = evaluated.loop
                #expect(loop.events.count == 16)
                #expect(loop.beatCount == 8)
                #expect(loop.events.map(\.startBeat) == [0, 0.25, 1.25, 1.5, 2, 2.25, 3.25, 3.5, 4, 4.25, 5.25, 5.5, 6, 6.25, 7.25, 7.5])
                #expect(loop.events.compactMap(\.midiNote) == [60, 67, 62, 69, 60, 67, 62, 69, 60, 67, 62, 69, 60, 67, 62, 69])
                #expect(loop.samples.contains { abs($0) > 0.01 })
                #expect(loop.samples.allSatisfy { $0.isFinite })
                #expect(loop.events.allSatisfy { $0.label == "Bank voices" })
                let half = loop.samples.count / 2
                var selectionDifference: Float = 0
                for index in 0..<half {
                    selectionDifference = max(selectionDifference, abs(loop.samples[index] - loop.samples[index + half]))
                }
                #expect(selectionDifference > 0.005)
                #expect(loop.rows.first?.patternText == "C4 D4 C4 D4")
                let engine = try AudioLoopEngine()
                defer { engine.stop() }
                engine.beginUpdate(revision: 51)
                try engine.submit(loop: loop, revision: 51)
                try engine.play()
                try await Task.sleep(for: .milliseconds(350))
                #expect(engine.outputMeter().interleavedSamples.contains { abs($0) > 0.0001 })
                try engine.setPlaybackRate(1.1)
                try engine.setLowPass(cutoff: 1_400)
                try engine.setDelay(mix: 0.2)
                try engine.setReverb(mix: 0.25)
                try await Task.sleep(for: .milliseconds(50))
                #expect(engine.snapshot().revision == 51)
                #expect(engine.snapshot().isPlaying)
                #expect(engine.outputMeter().interleavedSamples.allSatisfy { $0.isFinite })
                #expect(engine.outputMeter().interleavedSamples.contains { abs($0) > 0.0001 })
                let catalog = evaluated.catalog.descriptors
                let sourceGain = try #require(catalog.first { $0.address.target == .source(0) && $0.address.parameter == .gain }?.address)
                let cutoff = try #require(catalog.first { $0.address.target == .source(0) && $0.address.parameter == .cutoffHz }?.address)
                let track = try #require(catalog.first { $0.address.parameter == .trackLevel }?.address)
                let subtree = try #require(catalog.first {
                    if case .renderNode = $0.address.target { return $0.address.parameter == .gain }
                    return false
                }?.address)
                let controlled = try await evaluator.render(overrides: [
                    .init(address: sourceGain, value: .number(0.5)),
                    .init(address: cutoff, value: .number(2_000)),
                    .init(address: track, value: .number(0.6)),
                    .init(address: subtree, value: .number(0.2))
                ], revision: 51, generation: 1)
                var difference: Float = 0
                for (a, b) in zip(controlled.samples, loop.samples) { difference = max(difference, abs(a - b)) }
                #expect(difference > 0.001)
                let controlledIsFinite = controlled.samples.allSatisfy { $0.isFinite }
                #expect(controlledIsFinite)
                #expect(controlled.rows.map(\.resultLine) == loop.rows.map(\.resultLine))
                try engine.replace(loop: controlled, revision: 51, generation: 1)
                try await Task.sleep(for: .milliseconds(80))
                #expect(engine.snapshot().overrideGeneration == 1)
                #expect(engine.snapshot().revision == 51)
                #expect(engine.outputMeter().interleavedSamples.contains { abs($0) > 0.0001 })
                let released = try await evaluator.render(overrides: [], revision: 51, generation: 2)
                let restoresBaseline = released == loop
                #expect(restoresBaseline)
                try engine.replace(loop: released, revision: 51, generation: 2)
                try await Task.sleep(for: .milliseconds(80))
                #expect(engine.snapshot().overrideGeneration == 2)
                #expect(engine.snapshot().isPlaying)
                engine.beginUpdate(revision: 52)
                do {
                    _ = try await evaluator.evaluate(source: source.replacingOccurrences(of: url.path,
                        with: url.path + ".missing"), bpm: 120, beatsPerBar: 4)
                    Issue.record("A missing decoded asset must fail evaluation")
                } catch { #expect(error.localizedDescription.contains("unreadableFile")) }
                #expect(engine.snapshot().revision == 51)
                #expect(engine.snapshot().isPlaying)
                do {
                    _ = try await evaluator.evaluate(source: source.replacingOccurrences(of: "BusReturn(\"room\")",
                        with: "BusReturn(\"room\").send(to: \"room\", level: 1)"), bpm: 120, beatsPerBar: 4)
                    Issue.record("A cyclic bus must fail evaluation")
                } catch { #expect(error.localizedDescription.lowercased().contains("cycle")) }
                #expect(engine.snapshot().revision == 51)
                #expect(engine.snapshot().isPlaying)
                do {
                    _ = try await evaluator.evaluate(source: source.replacingOccurrences(of: "recovery: .milliseconds(100)",
                        with: "recovery: .zero"), bpm: 120, beatsPerBar: 4)
                    Issue.record("An invalid duck recovery must fail evaluation")
                } catch { #expect(error.localizedDescription.lowercased().contains("recovery")) }
                #expect(engine.snapshot().revision == 51)
                #expect(engine.snapshot().isPlaying)
                do {
                    _ = try await evaluator.evaluate(source: source.replacingOccurrences(of: "delay: .sixteenth",
                        with: "delay: .whole"), bpm: 120, beatsPerBar: 4)
                    Issue.record("An invalid swing must fail evaluation")
                } catch { #expect(error.localizedDescription.contains("invalidSwing")) }
                #expect(engine.snapshot().revision == 51)
                #expect(engine.snapshot().isPlaying)
                do {
                    _ = try await evaluator.evaluate(source: source.replacingOccurrences(of: "Portamento(duration: .seconds(.milliseconds(100)))",
                        with: "Portamento(duration: .seconds(.zero))"), bpm: 120, beatsPerBar: 4)
                    Issue.record("An invalid glide must fail evaluation")
                } catch { #expect(error.localizedDescription.contains("invalidPortamento")) }
                #expect(engine.snapshot().revision == 51)
                #expect(engine.snapshot().isPlaying)
                do {
                    _ = try await evaluator.evaluate(source: source.replacingOccurrences(of: "chorus(rateHz: 0.5",
                        with: "chorus(rateHz: 0.3"), bpm: 120, beatsPerBar: 4)
                    Issue.record("A nonperiodic modulation must fail evaluation")
                } catch { #expect(error.localizedDescription.contains("Modulation state does not repeat")) }
                #expect(engine.snapshot().revision == 51)
                #expect(engine.snapshot().isPlaying)
                do {
                    try engine.submit(loop: loop, revision: 50)
                    Issue.record("A stale native submission must fail")
                } catch let error as PlaybackError {
                    #expect(error == .staleRevision(50))
                } catch {
                    Issue.record("Expected staleRevision, got \(error)")
                }
                let recovered = try await evaluator.evaluate(source: source, bpm: 120, beatsPerBar: 4)
                #expect(recovered.beatCount == 8)
                engine.beginUpdate(revision: 53)
                try engine.submit(loop: recovered, revision: 53)
                try engine.setPlaybackRate(1.25)
                let deadline = ContinuousClock.now.advanced(by: .seconds(6))
                while engine.snapshot().revision != 53, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                #expect(engine.snapshot().revision == 53)
                #expect(engine.snapshot().isPlaying)
                #expect(engine.outputMeter().interleavedSamples.contains { abs($0) > 0.0001 })
                try await evaluator.shutdown()
            } catch {
                try await evaluator.shutdown()
                throw error
            }
        }

        @MainActor
        @Test(.timeLimit(.minutes(3)))
        func testRealSwiftEvaluationFailureCancellationTimeoutAndRecovery() async throws {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let workspace = package.appending(path: ".build/evaluator-integration")
            let evaluator = SourceEvaluator(packageURL: package, workspace: workspace, swiftExecutable: "/usr/bin/swift")
            let source = """
            struct Session: Music {
                var body: some Sound {
                    Track("Kick") {
                        Sample("kick") // 🥁 .gain(99)
                            .rhythm("x ~ x ~")
                            .gain(0.8)
                    }.gain(0.5)
                    Synthesizer(.sine)
                        .notes("C2 Eb2 G2 Bb2")
                        .transpose(12)
                        .gain(
                            0.2
                        )
                        .pan("-1 1")
                        .gain("1 0.5")
                }
            }
            """
            let first = try await evaluator.evaluate(source: source, bpm: 120, beatsPerBar: 4)
            #expect(first.events.count == 6)
            #expect(first.rows.map { $0.anchor?.line } == [5, 9])
            #expect(first.rows.map(\.resultLine) == [7, 15])
            #expect(first.rows.map { $0.patternText } == ["x ~ x ~", "C2 Eb2 G2 Bb2"])
            #expect(first.rows.allSatisfy { $0.anchor?.fileID.hasSuffix("Session.swift") == true })
            #expect(first.rows.allSatisfy { $0.peaks.contains { $0 > 0 } })
            #expect(first.events.compactMap(\.midiNote) == [48, 51, 55, 58])
            #expect(first.events.filter { $0.sourceID == 1 }.map(\.pan) == [-1, -1, 1, 1])
            #expect(first.events.filter { $0.sourceID == 1 }.map(\.gain) == [1, 1, 0.5, 0.5])
            #expect(first.samples.contains { abs($0) > 0.01 })
            let engine = try AudioLoopEngine()
            engine.beginUpdate(revision: 1)
            try engine.submit(loop: first, revision: 1)
            #expect(engine.snapshot().revision == 1)
            try engine.play()
            try await Task.sleep(for: .milliseconds(200))
            #expect(engine.snapshot().isPlaying)
            #expect(engine.snapshot().beatPosition > 0)

            engine.beginUpdate(revision: 2)
            do {
                _ = try await evaluator.evaluate(source: source + "\nunknownSymbol", bpm: 120, beatsPerBar: 4)
                Issue.record("Invalid Swift must fail")
            } catch { #expect(error.localizedDescription.contains("Session.swift")) }
            #expect(engine.snapshot().revision == 1)
            #expect(engine.snapshot().isPlaying)
            do {
                _ = try await evaluator.evaluate(source: source.replacingOccurrences(of: "x ~ x ~", with: "x ?"), bpm: 120, beatsPerBar: 4)
                Issue.record("Invalid music must fail")
            } catch { #expect(error.localizedDescription.contains("invalidRhythm")) }
            #expect(engine.snapshot().revision == 1)
            do {
                _ = try await evaluator.evaluate(source: source, bpm: 40, beatsPerBar: 3)
                Issue.record("A common period beyond the native duration bound must fail")
            } catch { #expect(error.localizedDescription.contains("liveWindowExceeded")) }
            #expect(engine.snapshot().revision == 1)
            #expect(engine.snapshot().isPlaying)

            let stuck = """
            func stuck() -> Sample { while true {} }
            struct Session: Music { var body: some Sound { stuck() } }
            """
            let cancelled = Task { try await evaluator.evaluate(source: stuck, bpm: 120, beatsPerBar: 4) }
            try await Task.sleep(for: .milliseconds(500))
            cancelled.cancel()
            do { _ = try await cancelled.value; Issue.record("Cancellation must fail") }
            catch is CancellationError {} catch { Issue.record("Expected cancellation, got \(error)") }
            do {
                _ = try await evaluator.evaluate(source: stuck, bpm: 120, beatsPerBar: 4)
                Issue.record("A nonterminating session must time out")
            } catch let error as EvaluationError {
                guard case .timedOut = error else { Issue.record("Expected timeout, got \(error)"); return }
            }
            let noisy = """
            func noisy() -> Sample {
                print(String(repeating: "z", count: 2_000_000))
                return Sample("kick")
            }
            struct Session: Music { var body: some Sound { noisy() } }
            """
            do {
                _ = try await evaluator.evaluate(source: noisy, bpm: 120, beatsPerBar: 4)
                Issue.record("Excessive output must fail")
            } catch { #expect(error.localizedDescription.contains("diagnostic limit")) }
            let logSize = try FileManager.default.attributesOfItem(atPath: workspace.appending(path: "process.log").path)[.size] as? NSNumber
            #expect(logSize?.intValue ?? Int.max <= 1_048_576)
            let recovered = try await evaluator.evaluate(source: source, bpm: 60, beatsPerBar: 3)
            #expect(recovered.events.count == first.events.count * 3)
            #expect(recovered.bpm == 60)
            #expect(recovered.beatsPerBar == 3)
            #expect(recovered.beatCount == 12)
            #expect(recovered.events.filter { $0.sourceID == 0 }.map(\.startBeat) == [0, 2, 4, 6, 8, 10])
            engine.stop()
            engine.beginUpdate(revision: 3)
            try engine.submit(loop: recovered, revision: 3)
            try engine.play()
            #expect(engine.snapshot().revision == 3)
            engine.stop()
            let nested = source.replacingOccurrences(of: "x ~ x ~", with: "x [x x] ~ x")
                .replacingOccurrences(of: ".gain(0.8)", with: ".gain(\"1 [0 0.5] 0.2 0.8\")")
            let patterned = try await evaluator.evaluate(source: nested, bpm: 120, beatsPerBar: 4)
            #expect(patterned.events.filter { $0.label == "Kick" }.map(\.gain) == [1, 0, 0.5, 0.8])
            #expect(patterned.events.filter { $0.label == "Kick" }.map(\.startBeat) == [0, 1, 1.5, 3])
            do {
                _ = try await evaluator.evaluate(source: nested.replacingOccurrences(of: "x [x x] ~ x", with: "x [x x ~ x"), bpm: 120, beatsPerBar: 4)
                Issue.record("Unbalanced pattern groups must fail")
            } catch { #expect(!(error.localizedDescription.isEmpty)) }
            try await evaluator.shutdown()
        }
    }
}
