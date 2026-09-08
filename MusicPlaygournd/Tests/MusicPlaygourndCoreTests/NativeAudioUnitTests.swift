import AVFoundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
    @MainActor struct NativeAudioUnitTests {
        @Test(.timeLimit(.minutes(1)))
        func playingHardwareGraphKeepsClockAndRevisionWhenEffectChanges() async throws {
            let engine = try AudioLoopEngine()
            defer { engine.stop() }
            let loop = try LoopRenderer().render(SoundCompiler().compile(
                Synthesizer(.sine).notes("A4").gain(0.001)), bpm: 120, beatsPerBar: 4)
            engine.beginUpdate(revision: 21)
            try engine.submit(loop: loop, revision: 21)
            try engine.play()
            try await Task.sleep(for: .milliseconds(350))
            let first = try engine.playbackClockAnchor()
            try await engine.selectAudioEffect(effect(engine))
            try await Task.sleep(for: .milliseconds(350))
            let changed = try engine.playbackClockAnchor()
            #expect(changed.revision == 21)
            #expect(changed.isPlaying)
            #expect(changed.accumulatedBeatPosition > first.accumulatedBeatPosition)
            #expect(changed.presentationHostTime > first.presentationHostTime)
            #expect(!engine.outputMeter().interleavedSamples.isEmpty)
            try engine.clearAudioEffect()
            try await Task.sleep(for: .milliseconds(350))
            #expect(try engine.playbackClockAnchor().accumulatedBeatPosition > changed.accumulatedBeatPosition)
            #expect(engine.audioEffectSnapshot() == .none)
        }

        private func effect(_ engine: AudioLoopEngine) throws -> HostedAudioUnitID {
            try #require(engine.discoverAudioEffects().first {
                $0.id.componentManufacturer == kAudioUnitManufacturer_Apple
                    && $0.id.componentSubType == kAudioUnitSubType_HighPassFilter
            }).id
        }

        private func engine() throws -> AudioLoopEngine {
            let engine = try AudioLoopEngine()
            let loop = try LoopRenderer().render(SoundCompiler().compile(
                Synthesizer(.sine).notes("A4").gain(0.1)), bpm: 120, beatsPerBar: 4)
            engine.beginUpdate(revision: 11)
            try engine.submit(loop: loop, revision: 11)
            return engine
        }

        private func renderedRMS(_ engine: AudioLoopEngine) throws -> Double {
            for _ in 0..<4 { _ = try engine.renderOfflineForTests(frameCount: 4096) }
            let samples = try engine.renderOfflineForTests(frameCount: 4096)
            #expect(samples.allSatisfy { $0.isFinite })
            return sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        }

        @Test(.timeLimit(.minutes(1)))
        func discoveredAppleEffectChangesNativePCMBypassesAndRestoresState() async throws {
            let plain = try engine()
            defer { plain.stop() }
            try plain.prepareOfflineRenderingForTests()
            try plain.play()
            let dry = try renderedRMS(plain)
            let hosted = try engine()
            defer { hosted.stop() }
            let id = try effect(hosted)
            try await hosted.selectAudioEffect(id)
            let state = try hosted.captureAudioEffectState()
            #expect(state.id == id)
            try hosted.prepareOfflineRenderingForTests()
            try hosted.play()
            let wet = try renderedRMS(hosted)
            #expect(dry > 0.01)
            #expect(wet < dry * 0.4)
            let missing = try HostedAudioUnitID(componentType: kAudioUnitType_Effect,
                componentSubType: 0, componentManufacturer: 0)
            await #expect(throws: HostedAudioUnitError.missingComponent) {
                try await hosted.selectAudioEffect(missing)
            }
            #expect(hosted.snapshot().isPlaying)
            #expect(hosted.snapshot().revision == 11)
            let meter = hosted.outputMeter().interleavedSamples
            #expect(!meter.isEmpty)
            #expect(meter.allSatisfy { $0.isFinite })
            try hosted.setAudioEffectBypassed(true)
            let bypass = try renderedRMS(hosted)
            #expect(abs(bypass - dry) < dry * 0.05)
            #expect(hosted.snapshot().revision == 11)
            let restored = try engine()
            defer { restored.stop() }
            try await restored.selectAudioEffect(id, restoring: state)
            try restored.prepareOfflineRenderingForTests()
            try restored.play()
            #expect(abs(try renderedRMS(restored) - wet) < max(0.0001, wet * 0.05))
            try hosted.clearAudioEffect()
            #expect(hosted.audioEffectSnapshot() == .none)
            #expect(abs(try renderedRMS(hosted) - dry) < dry * 0.05)
        }

        @Test(.timeLimit(.minutes(1)))
        func failedReplacementRollsBackAndDoubleFailureStopsWithPCMRetained() async throws {
            let engine = try engine()
            defer { engine.stop() }
            let id = try effect(engine)
            try await engine.selectAudioEffect(id)
            try engine.prepareOfflineRenderingForTests()
            try engine.play()
            _ = try renderedRMS(engine)
            let before = engine.snapshot()
            let selected = engine.audioEffectSnapshot()
            var starts = 0
            engine.audioUnitGraphStartCheck = {
                starts += 1
                if starts == 1 { throw HostedAudioUnitError.graphFailed("Injected start failure") }
            }
            do {
                try await engine.selectAudioEffect(id)
                Issue.record("A failed restart was accepted")
            } catch let error as HostedAudioUnitError {
                guard case .graphFailed = error else { throw error }
            }
            #expect(starts == 2)
            #expect(engine.audioEffectSnapshot() == selected)
            #expect(engine.snapshot().revision == before.revision)
            #expect(engine.snapshot().beatPosition == before.beatPosition)
            #expect(engine.snapshot().isPlaying)
            engine.audioUnitGraphStartCheck = { throw HostedAudioUnitError.graphFailed("Injected repeated failure") }
            do {
                try await engine.selectAudioEffect(id)
                Issue.record("A failed rollback was accepted")
            } catch let error as HostedAudioUnitError {
                guard case .rollbackFailed = error else { throw error }
            }
            #expect(!engine.snapshot().isPlaying)
            #expect(engine.snapshot().revision == 11)
            #expect(engine.snapshot().loop != nil)
            #expect(engine.audioEffectSnapshot() == selected)
            engine.audioUnitGraphStartCheck = nil
            try engine.play()
            #expect(try renderedRMS(engine) > 0)
        }

        @Test(.timeLimit(.minutes(1)))
        func supersededSelectionCannotAttachLateCandidate() async throws {
            let engine = try engine()
            defer { engine.stop() }
            let id = try effect(engine)
            var callback: AudioUnitInstantiation.Completion?
            engine.audioUnitStart = { _, completion in callback = completion }
            let selection = Task { @MainActor in try await engine.selectAudioEffect(id) }
            for _ in 0..<1000 where callback == nil { await Task.yield() }
            let completion = try #require(callback)
            engine.audioUnitStart = AudioUnitInstantiation.nativeStart
            try await engine.selectAudioEffect(id)
            do { try await selection.value; Issue.record("Superseded selection was accepted") }
            catch let error as HostedAudioUnitError { #expect(error == .superseded) }
            var unit: AVAudioUnit? = AVAudioUnitEQ(numberOfBands: 1)
            weak var released = unit
            completion(unit, nil)
            unit = nil
            for _ in 0..<100 where released != nil { await Task.yield() }
            #expect(released == nil)
            guard case .loaded(let descriptor, _) = engine.audioEffectSnapshot() else {
                Issue.record("The latest selection was not retained")
                return
            }
            #expect(descriptor.id == id)
            #expect(engine.snapshot().revision == 11)
        }

        @Test(.timeLimit(.minutes(1)))
        func nativeRequestTimeoutAndEmptyCallbackAreExplicit() async throws {
            let description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_HighPassFilter,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            let timeout = AudioUnitInstantiation()
            await #expect(throws: HostedAudioUnitError.timedOut) {
                try await timeout.value(for: description, timeout: .milliseconds(10), start: { _, _ in })
            }
            let empty = AudioUnitInstantiation()
            await #expect(throws: HostedAudioUnitError.instantiationFailed("The native callback returned no unit.")) {
                try await empty.value(for: description, start: { _, completion in completion(nil, nil) })
            }
        }
    }
}
