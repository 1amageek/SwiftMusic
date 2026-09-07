import SwiftMusic
import Testing

struct DomainTransformCompilationTests {
    @Test(.timeLimit(.minutes(3)))
    func phaseAndSpeedRespectDeclarationOrder() throws {
        let notes: NotePattern = "C4 D4"
        let compiler = SoundCompiler()
        let first = try compiler.compile(Synthesizer(.sine).notes(notes.phase(.quarter).fast(2)))
        let second = try compiler.compile(Synthesizer(.sine).notes(notes.fast(2).phase(.quarter)))
        #expect(first.events.map(\.start) == [.eighth, try MusicalTime(numerator: 3, denominator: 2)])
        #expect(second.events.map(\.start) == [.zero, .quarter])
        #expect(first.events.map { $0.pitch?.midiNote } == [62, 60])
        #expect(second.events.map { $0.pitch?.midiNote } == [62, 60])
    }

    @Test(.timeLimit(.minutes(3)))
    func reversalAndPhasePreserveDurationAndTransformOrder() throws {
        let notes: NotePattern = "[C4 D4] E4"
        let compiler = SoundCompiler()
        let first = try compiler.compile(Synthesizer(.sine).notes(notes.phase(.quarter).reversed()))
        let second = try compiler.compile(Synthesizer(.sine).notes(notes.reversed().phase(.quarter)))
        #expect(first.events.map { $0.pitch?.midiNote } == [60, 64, 62])
        #expect(first.events.map(\.start) == [.zero, .quarter, try MusicalTime(numerator: 3, denominator: 1)])
        #expect(second.events.map { $0.pitch?.midiNote } == [62, 60, 64])
        #expect(first.events.map(\.duration) == [.quarter, .half, .quarter])
    }

    @Test(.timeLimit(.minutes(3)))
    func localRepetitionReducesAlternativePeriodInsteadOfGrowingIt() throws {
        let notes: NotePattern = "<C4 D4>"
        let compiler = SoundCompiler()
        let two = try compiler.compile(Synthesizer(.sine).notes(notes.repeated(2)))
        #expect(two.extent == .whole)
        #expect(two.events.map(\.start) == [.zero, .half])
        #expect(two.events.map { $0.pitch?.midiNote } == [60, 62])
        let three = try compiler.compile(Synthesizer(.sine).notes(notes.repeated(3)))
        #expect(three.extent == (try MusicalTime(numerator: 8, denominator: 1)))
        #expect(three.events.map { $0.pitch?.midiNote } == [60, 62, 60, 62, 60, 62])
    }

    @Test(.timeLimit(.minutes(3)))
    func numericPhaseWrapsValuesBeforeSubsequentRepetition() throws {
        let pattern: GainPattern = "<1 0.5>"
        let sound = Sample("kick").rhythm("x*4")
        let compiler = SoundCompiler()
        let first = try compiler.compile(sound.gain(pattern.phase(.quarter).repeated(2)))
        let second = try compiler.compile(sound.gain(pattern.repeated(2).phase(.quarter)))
        #expect(first.events.map(\.gain) == [1, 1, 0.5, 0.5])
        #expect(second.events.map(\.gain) == [1, 0.5, 0.5, 1])
    }
}
