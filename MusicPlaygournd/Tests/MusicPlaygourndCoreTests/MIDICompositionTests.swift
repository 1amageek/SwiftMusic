import AVFoundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
@MainActor
struct MIDIClockCompositionTests {
    @Test(.timeLimit(.minutes(1)))
    func changingClockDestinationReleasesNotesOnPreviousOutput() async throws {
        let first = try VirtualMIDIEndpoints(label: "old output")
        let second = try VirtualMIDIEndpoints(label: "new output")
        let service = try CoreMIDIService()
        do {
            let a = try first.destinationID
            let b = try second.destinationID
            try await service.setOutput(a)
            let anchor = try PlaybackClockAnchor(
                presentationHostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.1),
                accumulatedBeatPosition: 0, beatsPerMinute: 120, loopBeatCount: 4,
                revision: 1, overrideGeneration: 0, isPlaying: true)
            await service.updateClockAnchor(anchor)
            try await service.send([MIDIScheduledMessage(hostTime: anchor.presentationHostTime,
                message: .noteOn(channel: 1, note: 60, velocity: 100))], to: a)
            _ = try await first.waitForMessages(atLeast: 1)
            try await service.setClockMode(.send(output: b))
            let old = try await first.waitForMessages(atLeast: 2)
            #expect(old.last?.message == .noteOff(channel: 1, note: 60, velocity: 0))
            #expect(await service.snapshot().outputID == b)
            let next = try PlaybackClockAnchor(
                presentationHostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.1),
                accumulatedBeatPosition: 1, beatsPerMinute: 120, loopBeatCount: 4,
                revision: 1, overrideGeneration: 0, isPlaying: true)
            await service.updateClockAnchor(next)
            try await service.scheduleClock(from: 1, through: 1.1)
            let new = try await second.waitForMessages(atLeast: 4)
            #expect(new.filter { $0.message == .clock }.count == 3)
            #expect(first.captureSnapshot().filter { $0.message == .clock }.isEmpty)
            await service.shutdown()
        } catch {
            await service.shutdown()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func nativeClockPreservesOrdinalsAcrossWrapRateStopAndContinue() async throws {
        let endpoints = try VirtualMIDIEndpoints(label: "clock composition")
        let service = try CoreMIDIService()
        do {
            let destination = try endpoints.destinationID
            try await service.setOutput(destination)
            try await service.setClockMode(.send(output: destination))
            let host = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.3)
            let first = try PlaybackClockAnchor(presentationHostTime: host,
                accumulatedBeatPosition: 0, beatsPerMinute: 120, loopBeatCount: 0.25,
                revision: 1, overrideGeneration: 0, isPlaying: true)
            await service.updateClockAnchor(first)
            try await service.scheduleClock(from: 0, through: 0.2)
            try await service.scheduleClock(from: 0.1, through: 0.3)
            let faster = try PlaybackClockAnchor(
                presentationHostTime: try first.hostTime(atBeat: 0.3),
                accumulatedBeatPosition: 0.3, beatsPerMinute: 240, loopBeatCount: 0.25,
                revision: 2, overrideGeneration: 1, isPlaying: true)
            await service.updateClockAnchor(faster)
            try await service.scheduleClock(from: 0.2, through: 0.6)
            let messages = try await endpoints.waitForMessages(atLeast: 16)
            #expect(messages.filter { $0.message == .start }.count == 1)
            let clocks = messages.filter { $0.message == .clock }
            #expect(clocks.count == 15)
            for (ordinal, message) in clocks.enumerated() {
                let anchor = ordinal < 8 ? first : faster
                #expect(message.hostTime == (try anchor.hostTime(atBeat: Double(ordinal) / 24)))
            }
            await service.updateClockAnchor(try PlaybackClockAnchor(
                presentationHostTime: mach_absolute_time(), accumulatedBeatPosition: 0.6,
                beatsPerMinute: 240, loopBeatCount: 0.25, revision: 2,
                overrideGeneration: 1, isPlaying: false))
            _ = try await endpoints.waitForMessages(atLeast: 17)
            let resume = try PlaybackClockAnchor(
                presentationHostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.2),
                accumulatedBeatPosition: 0.6, beatsPerMinute: 120, loopBeatCount: 0.25,
                revision: 2, overrideGeneration: 1, isPlaying: true)
            await service.updateClockAnchor(resume)
            try await service.scheduleClock(from: 0.6, through: 0.8)
            let resumed = try await endpoints.waitForMessages(atLeast: 23)
            #expect(resumed.filter { $0.message == .stop }.count == 1)
            #expect(resumed.filter { $0.message == .continue }.count == 1)
            #expect(resumed.filter { $0.message == .clock }.count == 20)
            await service.shutdown()
        } catch {
            await service.shutdown()
            throw error
        }
    }
}

}

extension NativeHostTests {
    @MainActor struct MIDICompositionTests {
        @Test(.timeLimit(.minutes(1)))
        func renderedPitchNativeOutputAndFailurePreservePlayback() async throws {
            let loop = try LoopRenderer().render(SoundCompiler().compile(
                Synthesizer(.sine).notes("C4").transpose(PitchPattern("12")).gate(0.025).gain(0.001)),
                bpm: 120, beatsPerBar: 4)
            let invalid = try LoopRenderer().render(SoundCompiler().compile(
                Synthesizer(.sine).notes("C4").transpose(PitchPattern("0.5"))),
                bpm: 120, beatsPerBar: 4)
            let endpoints = try VirtualMIDIEndpoints(label: "composition")
            let service = try CoreMIDIService()
            let engine = try AudioLoopEngine()
            defer { engine.stop() }
            do {
                engine.beginUpdate(revision: 91)
                try engine.submit(loop: loop, revision: 91)
                try engine.play()
                let destination = try endpoints.destinationID
                try await service.setOutput(destination)
                let host = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.3)
                let anchor = try PlaybackClockAnchor(presentationHostTime: host,
                    accumulatedBeatPosition: 0, beatsPerMinute: 120, loopBeatCount: loop.beatCount,
                    revision: 91, overrideGeneration: 0, isPlaying: true)
                await service.updateClockAnchor(anchor)
                try await service.schedule(loop: loop, from: 0, through: 0.2, channel: 3)
                let messages = try await endpoints.waitForMessages(atLeast: 2)
                #expect(messages.map(\.message) == [
                    .noteOn(channel: 3, note: 72, velocity: loop.events[0].velocity),
                    .noteOff(channel: 3, note: 72, velocity: 0)])
                #expect(messages[0].hostTime == host)
                #expect(messages[1].hostTime == (try anchor.hostTime(atBeat: loop.events[0].durationBeats)))
                await service.updateClockAnchor(try PlaybackClockAnchor(
                    presentationHostTime: mach_absolute_time(), accumulatedBeatPosition: 0.2,
                    beatsPerMinute: 120, loopBeatCount: loop.beatCount,
                    revision: 91, overrideGeneration: 0, isPlaying: false))
                await service.updateClockAnchor(try PlaybackClockAnchor(
                    presentationHostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.2),
                    accumulatedBeatPosition: 4, beatsPerMinute: 120, loopBeatCount: loop.beatCount,
                    revision: 91, overrideGeneration: 1, isPlaying: true))
                do {
                    try await service.schedule(loop: invalid, from: 4, through: 4.2, channel: 3)
                    Issue.record("Expressive MIDI projection was accepted")
                } catch let error as MIDIError {
                    #expect(error == .unsupportedProjection(.fractionalPitch))
                }
                #expect(engine.snapshot().revision == 91)
                #expect(engine.snapshot().isPlaying)
                #expect(endpoints.captureSnapshot().filter {
                    if case .noteOn = $0.message { return true }; return false
                }.count == 1)
                await service.shutdown()
            } catch {
                await service.shutdown()
                throw error
            }
        }
    }
}
