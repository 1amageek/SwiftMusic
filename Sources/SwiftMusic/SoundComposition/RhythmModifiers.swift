public extension Sound {
    func rhythm(_ pattern: RhythmPattern, cycle: MusicalTime = .whole) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .rhythm(pattern, cycle))
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
