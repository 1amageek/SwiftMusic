public extension Sound {
    func rhythm(_ pattern: RhythmPattern, cycle: MusicalTime) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .rhythm(pattern, cycle))
    }

    func rhythm(_ pattern: String, cycle: MusicalTime) throws -> ModifiedSound {
        try rhythm(RhythmPattern(pattern), cycle: cycle)
    }

    func offset(_ value: MusicalTime) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .offset(value))
    }

    func repeated(_ count: Int) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .repeated(count))
    }

    func fast(_ factor: UInt64) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .fast(factor))
    }

    func slow(_ factor: UInt64) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .slow(factor))
    }
}
