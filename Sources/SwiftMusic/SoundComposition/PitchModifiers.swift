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

    func chord(_ chord: Chord) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .chord(chord))
    }
}
