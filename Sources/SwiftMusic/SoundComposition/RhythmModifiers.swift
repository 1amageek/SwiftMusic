public extension Sound {
    func rhythm(
        _ pattern: RhythmPattern,
        cycle: MusicalTime = .whole,
        fileID: String = #fileID,
        line: Int = #line,
        column: Int = #column
    ) -> ModifiedSound {
        ModifiedSound(
            base: self,
            modifier: .rhythm(pattern, cycle, SoundSourceAnchor(fileID: fileID, line: line, column: column))
        )
    }

    func offset(_ value: MusicalTime) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .offset(value))
    }

    func repeated(_ count: Int) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .repeated(count))
    }

    func oneShot() -> ModifiedSound {
        ModifiedSound(base: self, modifier: .oneShot)
    }

    func fast(_ factor: UInt64) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .fast(factor))
    }

    func slow(_ factor: UInt64) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .slow(factor))
    }
}
