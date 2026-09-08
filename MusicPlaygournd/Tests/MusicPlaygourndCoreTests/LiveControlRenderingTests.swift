import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct LiveControlRenderingTests {
    private func session(_ sound: some Sound) throws -> LoopRenderSession {
        try LoopRenderSession(sound: SoundCompiler().compile(sound), bpm: 240, beatsPerBar: 4, revision: 2)
    }

    private func maximumError(_ lhs: PreparedLoop, _ rhs: PreparedLoop) throws -> Float {
        try #require(lhs.samples.count == rhs.samples.count)
        return zip(lhs.samples, rhs.samples).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    private func override(_ target: LiveControlTarget, _ parameter: LiveControlParameter,
                          _ value: Double) -> LiveControlOverride {
        LiveControlOverride(address: .init(revision: 2, target: target, parameter: parameter), value: .number(value))
    }

    @Test(.timeLimit(.minutes(3)))
    func sourceAndSubtreeControlsKeepDeclarationOrderAndReplaceAutomation() throws {
        let steps = try StepAutomation(values: [0, 1], cycle: .whole)
        let gain = try GainAutomation(.steps(steps), from: 0.1, to: 0.7)
        let pan = try PanAutomation(.steps(steps), from: -0.5, to: 0.5)
        let source = Synthesizer(.sine).notes("A4")
        let retained = try session(source.gain(gain).gain(0.5).pan(pan))
        let gainAddress = try #require(retained.catalog.descriptors.first {
            $0.address.parameter == .gain && $0.baseline == .automation
        }?.address)
        let panAddress = try #require(retained.catalog.descriptors.first {
            $0.address.parameter == .pan && $0.baseline == .automation
        }?.address)
        let result = try retained.render(overrides: [
            override(.source(0), .gain, 0.2),
            LiveControlOverride(address: gainAddress, value: .number(0.4)),
            LiveControlOverride(address: panAddress, value: .number(-1))
        ])
        let reference = try session(source.gain(0.2).gain(0.4).gain(0.5).pan(-1)).baseline
        #expect(try maximumError(result, reference) < 0.000001)
        #expect(try maximumError(retained.render(), retained.baseline) == 0)
    }

    @Test(.timeLimit(.minutes(3)))
    func trackControlsReplaceFaderAndCanReleasePanToBypass() throws {
        let track = Track("Voice") { Synthesizer(.sine).notes("A4").gain(0.3) }
        let retained = try session(track.trackLevel(0.5).trackPan(0.5))
        let result = try retained.render(overrides: [
            override(.track(0), .trackLevel, 0.2),
            LiveControlOverride(address: .init(revision: 2, target: .track(0), parameter: .trackPan), value: .bypassed)
        ])
        let reference = try session(track.trackLevel(0.2).trackPan(nil)).baseline
        #expect(try maximumError(result, reference) < 0.000001)
        #expect(try maximumError(retained.render(), retained.baseline) == 0)
    }

    @Test(.timeLimit(.minutes(3)))
    func pitchAndCutoffOverridesReplaceTheirContinuousAutomation() throws {
        let steps = try StepAutomation(values: [0, 1], cycle: .whole)
        let pitch = try PitchAutomation(.steps(steps), from: Semitones(value: -2), to: Semitones(value: 2))
        let cutoff = try CutoffAutomation(.steps(steps), from: Frequency(hertz: 100), to: Frequency(hertz: 2_000))
        let source = Synthesizer(.sine).notes("A4").transpose(1)
        let patterned = try session(Synthesizer(.sine).notes("A4 A4").lowPass("100 2000"))
        #expect(patterned.catalog.descriptors.first { $0.address.parameter == .cutoffHz }?.baseline == .automation)
        let retained = try session(source.transpose(pitch).lowPass(cutoff).gain(0.3))
        let result = try retained.render(overrides: [
            override(.source(0), .pitchOffsetSemitones, 12),
            override(.source(0), .cutoffHz, 400)
        ])
        let reference = try session(source.transpose(12).lowPass(Frequency(hertz: 400)).gain(0.3)).baseline
        #expect(try maximumError(result, reference) < 0.00001)
        #expect(throws: (any Error).self) {
            try retained.render(overrides: [override(.source(0), .pitchOffsetSemitones, 200)])
        }
        #expect(throws: (any Error).self) {
            try retained.render(overrides: [override(.source(0), .pitchOffsetSemitones, -200)])
        }
        #expect(try maximumError(retained.render(), retained.baseline) == 0)
    }
}
