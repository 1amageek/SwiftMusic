import Testing
@testable import SwiftMusic

struct ContinuousAutomationTests {
    @Test(.timeLimit(.minutes(3)))
    func normalizedSignalsUseExactBoundaryValues() throws {
        let sine = try LFO(waveform: .sine, rate: .synchronized(period: .whole))
        #expect(abs(try sine.value(at: 0) - 0.5) < 1e-12)
        let triangle = try LFO(waveform: .triangle, rate: .synchronized(period: .whole))
        #expect(try triangle.value(at: 0) == 0)
        #expect(try triangle.value(at: 0.5) == 1)
        let sawUp = try LFO(waveform: .sawUp, rate: .synchronized(period: .whole))
        #expect(try sawUp.value(at: 0) == 0)
        #expect(try sawUp.value(at: 0.5) == 0.5)
        #expect(try sawUp.value(at: 1) == 0)
        let sawDown = try LFO(waveform: .sawDown, rate: .synchronized(period: .whole))
        #expect(try sawDown.value(at: 0) == 1)
        #expect(try sawDown.value(at: 0.5) == 0.5)
        #expect(try sawDown.value(at: 1) == 1)
        let square = try LFO(waveform: .square, rate: .synchronized(period: .whole))
        #expect(try square.value(at: 0) == 0)
        #expect(try square.value(at: 0.5) == 1)
        #expect(try square.value(at: 0.999) == 1)
        #expect(try square.value(at: 1) == 0)
        let steps = try StepAutomation(values: [0, 1, 0.25], cycle: .whole)
        #expect(try steps.value(at: 0) == 0)
        #expect(try steps.value(at: 1.0 / 3.0) == 1)
        #expect(try steps.value(at: 2.0 / 3.0) == 0.25)

        let curve = try AutomationCurve(points: [
            AutomationPoint(position: .zero, value: 0, interpolationToNext: .linear),
            AutomationPoint(position: .half, value: 1, interpolationToNext: .smoothstep)
        ], cycle: .whole)
        #expect(try curve.value(at: 0) == 0)
        #expect(try curve.value(at: 0.5) == 1)
        #expect(abs(try curve.value(at: 0.75) - 0.5) < 1e-12)
        #expect(abs(try curve.value(at: 1) - 0) < 1e-12)
    }

    @Test(.timeLimit(.minutes(3)))
    func descriptorsRejectInvalidRangesAndRetainDescendingMappings() throws {
        #expect(throws: AutomationError.invalidPhase) {
            try LFO(waveform: .sine, rate: .synchronized(period: .whole), phase: 1)
        }
        #expect(throws: AutomationError.invalidRate) {
            try LFO(waveform: .sine, rate: .synchronized(period: .zero))
        }
        #expect(throws: AutomationError.emptyValues) {
            try StepAutomation(values: [], cycle: .whole)
        }
        #expect(throws: AutomationError.invalidCycle) {
            try StepAutomation(values: [0], cycle: .zero)
        }
        #expect(throws: AutomationError.invalidValue(index: 0)) {
            try StepAutomation(values: [1.1], cycle: .whole)
        }
        #expect(throws: AutomationError.invalidValue(index: 0)) {
            try AutomationCurve(points: [
                AutomationPoint(position: .zero, value: .nan, interpolationToNext: .hold)
            ], cycle: .whole)
        }
        #expect(throws: AutomationError.invalidValue(index: 0)) {
            try AutomationCurve(points: [
                AutomationPoint(position: .zero, value: 1.1, interpolationToNext: .hold)
            ], cycle: .whole)
        }
        #expect(throws: AutomationError.invalidCycle) {
            try AutomationCurve(points: [
                AutomationPoint(position: .zero, value: 0, interpolationToNext: .hold)
            ], cycle: .zero)
        }
        #expect(throws: AutomationError.invalidPosition(index: 1)) {
            try AutomationCurve(points: [
                AutomationPoint(position: .zero, value: 0, interpolationToNext: .hold),
                AutomationPoint(position: .zero, value: 1, interpolationToNext: .hold)
            ], cycle: .whole)
        }
        let normalized = AutomationSignal.steps(
            try StepAutomation(values: [0, 1], cycle: .whole)
        )
        #expect(throws: AutomationError.invalidEndpoint) {
            try GainAutomation(normalized, from: -1, to: 1)
        }
        #expect(throws: AutomationError.invalidEndpoint) {
            try PanAutomation(normalized, from: -1, to: 2)
        }
        #expect(throws: AutomationError.invalidEndpoint) {
            try PitchAutomation(
                normalized,
                from: try Semitones(value: -Double.greatestFiniteMagnitude),
                to: try Semitones(value: Double.greatestFiniteMagnitude)
            )
        }
        let gain = try GainAutomation(
            .steps(try StepAutomation(values: [0, 1], cycle: .whole)), from: 2, to: 0
        )
        #expect(try gain.value(at: 0) == 2)
        #expect(try gain.value(at: 0.5) == 0)
        let pan = try PanAutomation(
            .steps(try StepAutomation(values: [0, 1], cycle: .whole)), from: 1, to: -1
        )
        #expect(try pan.value(at: 0) == 1)
        #expect(try pan.value(at: 0.5) == -1)
    }

    @Test(.timeLimit(.minutes(3)))
    func curveRejectsUnrepresentableAdjacentDoublePositionsBeforeEvaluation() throws {
        let base = UInt64(1) << 53
        let first = try MusicalTime(numerator: base, denominator: 1)
        let adjacent = try MusicalTime(numerator: base + 1, denominator: 1)
        let cycle = try MusicalTime(numerator: base + 2, denominator: 1)
        #expect(throws: AutomationError.timingOverflow) {
            try AutomationCurve(points: [
                AutomationPoint(position: .zero, value: 0, interpolationToNext: .linear),
                AutomationPoint(position: first, value: 0.5, interpolationToNext: .linear),
                AutomationPoint(position: adjacent, value: 1, interpolationToNext: .linear)
            ], cycle: cycle)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func liveCutoffAutomationRetainsItsBaseEventCutoff() throws {
        let signal = AutomationSignal.steps(
            try StepAutomation(values: [0, 1], cycle: .whole)
        )
        let cutoff = try CutoffAutomation(
            signal, from: try Frequency(hertz: 200), to: try Frequency(hertz: 4_000)
        )
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .beats(32))
        let compiled = try SoundCompiler().compile(
            Synthesizer(.sine).notes("C4 C4 C4 C4").lowPass(cutoff),
            liveLoop: policy
        )
        #expect(compiled.events.map(\.cutoffHz) == [200, 200, 200, 200])
    }

    @Test(.timeLimit(.minutes(3)))
    func pitchAutomationRejectsLaterWritersAndNoise() throws {
        let pitch = try PitchAutomation(
            .steps(try StepAutomation(values: [0, 1], cycle: .whole)),
            from: try Semitones(value: 0), to: try Semitones(value: 12)
        )
        #expect(throws: SoundCompilationError.pitchOutOfRange) {
            try SoundCompiler().compile(
                Synthesizer(.sine).notes("C4").transpose(pitch)
                    .notes([try Pitch(midiNote: 127)])
            )
        }
        #expect(throws: SoundCompilationError.self) {
            try SoundCompiler().compile(Synthesizer(.noise).notes("C4").transpose(pitch))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func oneShotDoesNotRecreateAnOnsetPatternRecurrence() throws {
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .beats(32))
        let oneShot = Synthesizer(.sine).rhythm("x").oneShot()
        let longCycle = try SoundCompiler().compile(
            oneShot.gain(try GainPattern(validating: "1"), cycle: .beats(33)),
            liveLoop: policy
        )
        let slowPattern = try SoundCompiler().compile(
            oneShot.gain(try GainPattern(validating: "1").slow(64)),
            liveLoop: policy
        )
        #expect(longCycle.extent == .whole)
        #expect(slowPattern.extent == .whole)
        #expect(longCycle.events.count == 1)
        #expect(slowPattern.events.count == 1)
    }

    @Test(.timeLimit(.minutes(3)))
    func compilerRetainsContinuousDescriptorsAndOrderedNodes() throws {
        let steps = try StepAutomation(values: [0, 1], cycle: .whole)
        let gain = try GainAutomation(.steps(steps), from: 0.2, to: 0.8)
        let pan = try PanAutomation(.steps(steps), from: -1, to: 1)
        let pitch = try PitchAutomation(
            .steps(steps), from: try Semitones(value: -2), to: try Semitones(value: 2)
        )
        let cutoff = try CutoffAutomation(
            .steps(steps), from: try Frequency(hertz: 200), to: try Frequency(hertz: 4_000)
        )
        let compiled = try SoundCompiler().compile(
            Synthesizer(.sine)
                .notes("C4")
                .transpose(pitch)
                .lowPass(cutoff)
                .gain(gain)
                .pan(pan)
        )

        #expect(compiled.sources.count == 1)
        #expect(compiled.sources[0].pitchAutomation == pitch)
        #expect(compiled.sources[0].cutoffAutomation == cutoff)
        #expect(compiled.events[0].cutoffHz == 200)
        #expect(compiled.renderNodes.count == 3)
        #expect(compiled.renderNodes[0] == .source(sourceID: 0))
        #expect(compiled.renderNodes[1] == .gainAutomation(input: 0, automation: gain))
        #expect(compiled.renderNodes[2] == .panAutomation(input: 1, automation: pan))
    }

    @Test(.timeLimit(.minutes(3)))
    func synchronizedAutomationContributesToLiveWindow() throws {
        let lfo = try LFO(waveform: .sawUp, rate: .synchronized(period: .beats(3)))
        let gain = try GainAutomation(.lfo(lfo), from: 0, to: 1)
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .beats(32))
        let compiled = try SoundCompiler().compile(
            Synthesizer(.sine).rhythm("x x", cycle: .whole).gain(gain),
            liveLoop: policy
        )
        #expect(compiled.playbackMode == .seamlessLoop)
        #expect(compiled.extent == .beats(12))
        #expect(compiled.events.count == 6)
    }

    @Test(.timeLimit(.minutes(3)))
    func eventTimeTransformsDoNotScaleContinuousAutomationClocks() throws {
        let automation = try GainAutomation(
            .steps(try StepAutomation(values: [0, 1], cycle: .beats(8))),
            from: 0, to: 1
        )
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .beats(32))
        let source = Synthesizer(.sine).rhythm("x")
        let automationBeforeFast = try SoundCompiler().compile(
            source.gain(automation).fast(2), liveLoop: policy
        )
        let fastBeforeAutomation = try SoundCompiler().compile(
            source.fast(2).gain(automation), liveLoop: policy
        )
        #expect(automationBeforeFast.extent == .beats(8))
        #expect(fastBeforeAutomation.extent == .beats(8))
        #expect(automationBeforeFast.events.map(\.start) == [.zero, .beats(2), .beats(4), .beats(6)])
        #expect(fastBeforeAutomation.events.map(\.start) == [.zero, .beats(2), .beats(4), .beats(6)])
    }
}
