public extension Sound {
    func notes(_ pitches: [Pitch]) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .notes(pitches))
    }

    func notes(_ pitches: Pitch...) -> ModifiedSound {
        notes(pitches)
    }

    func notes(_ pattern: NotePattern, cycle: MusicalTime = .whole) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .notePattern(pattern, cycle))
    }

    func transpose(_ semitones: Int) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .transpose(semitones))
    }

    func chord(_ chord: Chord) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .chord(chord))
    }
}
