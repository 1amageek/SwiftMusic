import Testing
import SwiftMusic

struct HarmonyCompilationTests {
    private let compiler = SoundCompiler()

    @Test(.timeLimit(.minutes(3)))
    func scaleDegreesPreserveNegativeOctavesFractionalOffsetsAndProvenance() throws {
        let key = Key(tonic: try Pitch(midiNote: 60), scale: .major)
        let degrees = [
            ScaleDegree(1), ScaleDegree(2), ScaleDegree(0), ScaleDegree(-1), ScaleDegree(8)
        ]
        let result = try compiler.compile(
            Synthesizer(.sine)
                .rhythm("x x x x x")
                .notes(degrees, in: key, fileID: "Harmony.swift", line: 17, column: 4)
        )

        #expect(result.events.count == 5)
        #expect(result.events.compactMap(\.pitch?.midiNote) == [60, 60, 60, 60, 60])
        #expect(result.events.map(\.pitchOffsetSemitones) == [0, 2, -1, -3, 12])
        #expect(result.events.allSatisfy { $0.patternStepIndex == nil })
        #expect(result.sources[0].patternAnchor == SoundSourceAnchor(fileID: "Harmony.swift", line: 17, column: 4))
        #expect(result.sources[0].patternText == nil)
    }

    @Test(.timeLimit(.minutes(3)))
    func scalesAndFractionalChordsValidateWithoutTruncatingIntervals() throws {
        #expect(Scale.chromatic.intervals.map(\.value) == Array(0...11).map(Double.init))
        #expect(Scale.major.intervals.map(\.value) == [0, 2, 4, 5, 7, 9, 11])
        #expect(Scale.naturalMinor.intervals.map(\.value) == [0, 2, 3, 5, 7, 8, 10])

        let custom = try Scale(intervals: try [0.0, 3.5, 7.25].map { try Semitones(value: $0) })
        #expect(custom.intervals.map(\.value) == [0, 3.5, 7.25])
        #expect(throws: HarmonyError.invalidScale) {
            let intervals = try [1.0, 3.0].map { try Semitones(value: $0) }
            try Scale(intervals: intervals)
        }
        #expect(throws: HarmonyError.invalidScale) {
            let intervals = try [0.0, 12.0].map { try Semitones(value: $0) }
            try Scale(intervals: intervals)
        }

        let chord = try Chord(intervals: try [0.0, 3.5, 7.0].map { try Semitones(value: $0) })
        let result = try compiler.compile(Synthesizer(.sine).notes([try Pitch(midiNote: 60)]).chord(chord))
        #expect(result.events.compactMap(\.pitch?.midiNote) == [60, 63, 67])
        #expect(result.events.map(\.pitchOffsetSemitones) == [0, 0.5, 0])
        #expect(result.events.compactMap(\.harmonyVoiceIndex) == [0, 1, 2])
        #expect(throws: SoundParameterError.self) { try Chord(intervals: []) }
    }

    @Test(.timeLimit(.minutes(3)))
    func voicingAndInversionUseDeclaredVoicesAndStableTieBreaks() throws {
        let pitch = try Pitch(midiNote: 60)
        let voicing = try Voicing(octaveOffsets: [0, 1, -1])
        let voiced = try compiler.compile(
            Synthesizer(.sine).notes([pitch]).chord(.major).voicing(voicing)
        )
        let voicedEffective = voiced.events.compactMap { event -> Double? in
            guard let pitch = event.pitch else { return nil }
            return Double(pitch.midiNote) + event.pitchOffsetSemitones
        }
        #expect(voicedEffective == [60, 76, 55])
        #expect(voiced.events.compactMap(\.harmonyVoiceIndex) == [0, 1, 2])

        let unisonChord = try Chord(intervals: try [0.0, 0.0].map { try Semitones(value: $0) })
        let inverted = try compiler.compile(
            Synthesizer(.sine).notes([pitch]).chord(unisonChord).inverted(1)
        )
        let invertedEffective = inverted.events.compactMap { event -> Double? in
            guard let pitch = event.pitch else { return nil }
            return Double(pitch.midiNote) + event.pitchOffsetSemitones
        }
        #expect(invertedEffective == [72, 60])
        #expect(inverted.events.compactMap(\.harmonyVoiceIndex) == [0, 1])

        #expect(throws: HarmonyError.invalidVoicing) { try Voicing(octaveOffsets: []) }
        #expect(throws: HarmonyError.invalidVoicing) { try Voicing(octaveOffsets: [Int.max]) }
    }

    @Test(.timeLimit(.minutes(3)))
    func arpeggioOrdersGrowExtentAndCheckExpansionBeforeAllocation() throws {
        let base = Synthesizer(.sine).notes([try Pitch(midiNote: 60)]).chord(.major)
        let cases: [(ArpeggioOrder, [Double], [MusicalTime], MusicalTime)] = [
            (.asDeclared, [60, 64, 67], [.zero, .quarter, .half], .beats(3)),
            (.up, [60, 64, 67], [.zero, .quarter, .half], .beats(3)),
            (.down, [67, 64, 60], [.zero, .quarter, .half], .beats(3)),
            (.upDown, [60, 64, 67, 64], [.zero, .quarter, .half, .beats(3)], .beats(4))
        ]

        for (order, expectedPitches, expectedStarts, expectedExtent) in cases {
            let arpeggio = try Arpeggio(order: order, step: .quarter)
            let result = try compiler.compile(base.arpeggiated(arpeggio))
            let pitches = result.events.compactMap { event -> Double? in
                guard let pitch = event.pitch else { return nil }
                return Double(pitch.midiNote) + event.pitchOffsetSemitones
            }
            #expect(pitches == expectedPitches)
            #expect(result.events.map(\.start) == expectedStarts)
            #expect(result.extent == expectedExtent)
            #expect(Set(result.events.compactMap(\.harmonyGroupID)).count == 1)
            #expect(Set(result.events.compactMap(\.harmonyOccurrenceID)).count == 1)
        }

        let voicing = try Voicing(octaveOffsets: [1, 0, 0])
        let arp = try Arpeggio(order: .up, step: .quarter)
        let before = try compiler.compile(base.voicing(voicing).arpeggiated(arp))
        let after = try compiler.compile(base.arpeggiated(arp).voicing(voicing))
        #expect(before.events.map { Double($0.pitch!.midiNote) + $0.pitchOffsetSemitones } == [64, 67, 72])
        #expect(after.events.map { Double($0.pitch!.midiNote) + $0.pitchOffsetSemitones } == [72, 64, 67])
        #expect(Set(after.events.compactMap(\.harmonyOccurrenceID)).count == 1)
        let upDown = base.arpeggiated(try Arpeggio(order: .upDown, step: .quarter))
        for (count, expected) in [(2, [72.0, 76, 67, 76]), (-2, [60.0, 52, 55, 52])] {
            let inversion = try compiler.compile(upDown.inverted(count))
            #expect(inversion.events.map { Double($0.pitch!.midiNote) + $0.pitchOffsetSemitones } == expected)
            #expect(inversion.events.map(\.harmonyVoiceIndex) == [0, 1, 2, 1])
            #expect(inversion.events.map(\.start) == [.zero, .quarter, .half, .beats(3)])
            #expect(Set(inversion.events.compactMap(\.harmonyOccurrenceID)).count == 1)
        }
        let bare = Synthesizer(.sine).notes("C4")
        for invalid in [bare.voicing(voicing), bare.inverted(1), bare.arpeggiated(arp)] {
            #expect(throws: HarmonyError.missingHarmony) { try compiler.compile(invalid) }
        }
        let limited = SoundCompiler(limits: try .init(maximumEvents: 3))
        #expect(throws: SoundCompilationError.maximumEventsExceeded(limit: 3)) {
            try limited.compile(base.arpeggiated(try Arpeggio(order: .upDown, step: .quarter)))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func repeatedAndLiveChordOccurrencesRemainIndependent() throws {
        let pitch = try Pitch(midiNote: 60)
        let finite = try compiler.compile(
            Synthesizer(.sine)
                .rhythm("x", cycle: .quarter)
                .notes([pitch])
                .chord(.major)
                .repeated(2)
        )
        let finiteIDs = finite.events.compactMap(\.harmonyOccurrenceID)
        #expect(finiteIDs.count == 6)
        #expect(Set(finiteIDs).count == 2)
        #expect(Set(finiteIDs.prefix(3)).count == 1)
        #expect(Set(finiteIDs.suffix(3)).count == 1)
        #expect(finiteIDs.prefix(3).first != finiteIDs.suffix(3).first)

        let live = try compiler.compile(
            Synthesizer(.sine)
                .rhythm("x", cycle: .quarter)
                .notes([pitch])
                .chord(.major),
            liveLoop: try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)
        )
        let liveIDs = live.events.compactMap(\.harmonyOccurrenceID)
        #expect(live.events.count == 12)
        #expect(Set(liveIDs).count == 4)
        for id in Set(liveIDs) {
            #expect(liveIDs.filter { $0 == id }.count == 3)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func legatoAndPortamentoResolveFinalPitchLanesForFiniteAndLiveEvents() throws {
        let c4 = try Pitch(midiNote: 60)
        let d4 = try Pitch(midiNote: 62)
        let portamento = try Portamento(duration: .beats(.quarter))
        let sound = Synthesizer(.sine)
            .rhythm("x x", cycle: .half)
            .notes([c4, d4])
            .transpose(12)
            .portamento(portamento)
            .gate(0.2)
            .legato()

        let finite = try compiler.compile(sound)
        #expect(finite.events.count == 2)
        #expect(finite.events.map(\.gate) == [1, 0.2])
        #expect(finite.events.map(\.portamentoStartMIDINote) == [nil, 72])
        #expect(finite.sources[0].portamento == portamento)

        let live = try compiler.compile(
            sound,
            liveLoop: try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)
        )
        #expect(live.events.count == 4)
        #expect(live.events.allSatisfy { $0.gate == 1 })
        #expect(live.events.first?.portamentoStartMIDINote == 74)
        #expect(live.events.dropFirst().allSatisfy { $0.portamentoStartMIDINote != nil })
        let overlapping = try compiler.compile(sound.legato(Legato(overlap: .sixteenth)))
        #expect(overlapping.events.map(\.gate) == [1.25, 0.2])
        let oneShot = try compiler.compile(sound.oneShot(),
            liveLoop: LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole))
        #expect(oneShot.events.first?.portamentoStartMIDINote == nil)
        #expect(oneShot.events.last?.gate == 0.2)

        #expect(throws: HarmonyError.invalidPortamento) {
            try Portamento(duration: .beats(.zero))
        }
        #expect(throws: SoundCompilationError.self) {
            try compiler.compile(Sample("noise").portamento(portamento))
        }
    }
}
