import Observation
import Testing
@testable import SwiftMusic

@MainActor
struct PerformanceModelTests {
    @MainActor @Observable final class Model {
        var gain = 0.5
        var position = SpatialPosition(x: 0, depth: 0)
    }
    struct Piece: Music {
        @Performance(Model.self) private var model
        var body: some Sound { Synthesizer(.sine).gain(model.gain).position(model.position) }
    }
    @Test(.timeLimit(.minutes(1)))
    func resolvesExactModelAndRejectsMissingBeforeBody() throws {
        let compiler = SoundCompiler()
        #expect(throws: SoundCompilationError.self) { try compiler.compile(Piece()) }
        let model = Model()
        let value = try compiler.compile(Piece().performance(model))
        let expected = try compiler.compile(Synthesizer(.sine).gain(0.5).pan(0))
        #expect(value == expected)
        let other = Model()
        other.gain = 0.25
        let overridden = try compiler.compile(Piece().performance(model).performance(other))
        let expectedOther = try compiler.compile(Synthesizer(.sine).gain(0.25).pan(0))
        #expect(overridden == expectedOther)
        if case .failed(_, .missingPerformance) = LiveMusicUpdate.prepare(revision: 1, music: Piece()) {} else {
            Issue.record("Missing performance must be a typed failed update")
        }
    }
    @Test(.timeLimit(.minutes(1)))
    func observesCoalescedChangesRearmsAndInvalidates() async throws {
        let model = Model()
        var notifications = 0
        let session = PerformanceObservationSession(Piece().performance(model)) { notifications += 1 }
        if case .prepared = session.prepare(revision: 1) {} else { Issue.record("Initial preparation failed") }
        model.gain = 0.2
        model.position = .init(x: 1, depth: 0.5)
        try await Task.sleep(for: .milliseconds(30))
        #expect(notifications == 1)
        if case .prepared = session.prepare(revision: 2) {} else { Issue.record("Updated preparation failed") }
        model.gain = 0.3
        try await Task.sleep(for: .milliseconds(30))
        #expect(notifications == 2)
        _ = session.prepare(revision: 3)
        model.gain = 0.4
        session.invalidate()
        try await Task.sleep(for: .milliseconds(30))
        #expect(notifications == 2)
        if case .failed = session.prepare(revision: 4) {} else { Issue.record("Invalidated session must reject preparation") }
    }
    @MainActor @Observable final class Probe { var evaluations = 0 }
    struct CheckedPiece: Music {
        let probe: Probe
        @Performance(Model.self) private var model
        var body: some Sound {
            probe.evaluations += 1
            return Synthesizer(.sine).gain(model.gain)
        }
    }
    struct HiddenPiece: Music, CustomReflectable {
        @Performance(Model.self) private var model
        var customMirror: Mirror { Mirror(reflecting: 0) }
        var body: some Sound { Synthesizer(.sine).gain(model.gain) }
    }
    struct ExplicitPiece: PerformanceRequirementProviding, CustomReflectable {
        @Performance(Model.self) private var model
        var customMirror: Mirror { Mirror(reflecting: 0) }
        var performanceRequirements: [PerformanceRequirement] { [.init(Model.self)] }
        var body: some Sound { Synthesizer(.sine).gain(model.gain) }
    }
    @Test(.timeLimit(.minutes(1)))
    func preflightRejectsHiddenAndMissingProvidersWithoutEvaluatingBody() throws {
        let probe = Probe()
        let piece = CheckedPiece(probe: probe)
        let compiler = SoundCompiler()
        #expect(throws: SoundCompilationError.self) { try compiler.compile(piece) }
        #expect(probe.evaluations == 0)
        let model = Model()
        _ = try compiler.compile(piece.performance(model).performance(probe))
        #expect(probe.evaluations == 1)
        #expect(throws: SoundCompilationError.self) { try compiler.compile(HiddenPiece().performance(model)) }
        #expect(throws: SoundCompilationError.self) { try compiler.compile(ExplicitPiece()) }
        let explicit = try compiler.compile(ExplicitPiece().performance(model))
        #expect(explicit == (try compiler.compile(Synthesizer(.sine).gain(0.5))))
    }
    @Test(.timeLimit(.minutes(1)))
    func invalidationReleasesOwnedModelsAndInvalidValuesFailPreparation() {
        var model: Model? = Model()
        weak var retainedModel = model
        let session = PerformanceObservationSession(Piece().performance(model!)) {}
        model!.gain = .nan
        if case .failed = session.prepare(revision: 1) {} else { Issue.record("Invalid values must fail preparation") }
        model = nil
        #expect(retainedModel != nil)
        session.invalidate()
        #expect(retainedModel == nil)
    }

    struct RepeatedRequirements: PerformanceRequirementProviding {
        let count: Int
        let probe: Probe
        var performanceRequirements: [PerformanceRequirement] {
            Array(repeating: PerformanceRequirement(Model.self), count: count)
        }
        var body: some Sound {
            probe.evaluations += 1
            return Synthesizer(.sine)
        }
    }
    @Test(.timeLimit(.minutes(1)))
    func requirementLimitFailsBeforeBody() throws {
        let compiler = SoundCompiler()
        let probe = Probe()
        let model = Model()
        _ = try compiler.compile(RepeatedRequirements(count: 1_024, probe: probe).performance(model))
        #expect(probe.evaluations == 1)
        #expect(throws: SoundCompilationError.self) {
            try compiler.compile(RepeatedRequirements(count: 1_025, probe: probe).performance(model))
        }
        #expect(probe.evaluations == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func replacementRetainsOnlyCurrentProvider() throws {
        var original: Model? = Model()
        weak var released = original
        var music = Piece().performance(original!)
        original = nil
        for _ in 0..<1_025 { music = music.performance(Model()) }
        #expect(released == nil)
        #expect(try SoundCompiler().compile(music) == SoundCompiler().compile(Piece().performance(Model())))
    }

    struct LocatedFailurePiece: Music {
        let probe: Probe
        @Performance(Model.self) private var model
        var body: some Sound {
            probe.evaluations += 1
            let pattern: GainPattern = "1 nope"
            return Synthesizer(.sine).gain(model.gain)
                .gain(pattern, fileID: "Session.swift", line: 12, column: 8)
        }
    }
    @Test(.timeLimit(.minutes(1)))
    func detailedPreparationPreservesLocationAndEvaluatesBodyOnce() throws {
        let model = Model()
        let probe = Probe()
        let valid = PerformanceObservationSession(CheckedPiece(probe: probe).performance(model)) {}
        defer { valid.invalidate() }
        _ = try valid.prepareDetailed()
        #expect(probe.evaluations == 1)
        let invalid = PerformanceObservationSession(LocatedFailurePiece(probe: probe).performance(model)) {}
        defer { invalid.invalidate() }
        do {
            _ = try invalid.prepareDetailed()
            Issue.record("Expected located failure")
        } catch let error as LocatedSoundCompilationError {
            #expect(error.anchor == SoundSourceAnchor(fileID: "Session.swift", line: 12, column: 8))
            #expect(error.utf8Offset == 2)
            #expect(error.patternText == "1 nope")
        }
        #expect(probe.evaluations == 2)
        if case .failed(_, .invalidGainPattern) = invalid.prepare(revision: 1) {} else {
            Issue.record("Ordinary preparation must retain its unlocated typed error surface")
        }
        #expect(probe.evaluations == 3)
    }

}
