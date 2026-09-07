public extension Sound {
    func notes(
        _ pitches: [Pitch],
        fileID: String = #fileID,
        line: Int = #line,
        column: Int = #column
    ) -> ModifiedSound {
        ModifiedSound(
            base: self,
            modifier: .notes(pitches, SoundSourceAnchor(fileID: fileID, line: line, column: column))
        )
    }

    func notes(
        _ pitches: Pitch...,
        fileID: String = #fileID,
        line: Int = #line,
        column: Int = #column
    ) -> ModifiedSound {
        notes(pitches, fileID: fileID, line: line, column: column)
    }

    func notes(
        _ pattern: NotePattern,
        cycle: MusicalTime = .whole,
        fileID: String = #fileID,
        line: Int = #line,
        column: Int = #column
    ) -> ModifiedSound {
        ModifiedSound(
            base: self,
            modifier: .notePattern(pattern, cycle, SoundSourceAnchor(fileID: fileID, line: line, column: column))
        )
    }

    func transpose(_ semitones: Int) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .transpose(semitones))
    }

    func transpose(_ pattern: PitchPattern, cycle: MusicalTime = .whole) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .pitchPattern(pattern, cycle))
    }

    func transpose(_ automation: PitchAutomation) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .pitchAutomation(automation))
    }

    func notes(_ degrees: [ScaleDegree], in key: Key,
               fileID: String = #fileID, line: Int = #line, column: Int = #column) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .scaleNotes(degrees, key,
            SoundSourceAnchor(fileID: fileID, line: line, column: column)))
    }

    func voicing(_ value: Voicing) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .voicing(value))
    }

    func inverted(_ count: Int) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .inversion(count))
    }

    func arpeggiated(_ value: Arpeggio) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .arpeggio(value))
    }

    func portamento(_ value: Portamento) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .portamento(value))
    }

    func chord(_ chord: Chord) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .chord(chord))
    }
}
