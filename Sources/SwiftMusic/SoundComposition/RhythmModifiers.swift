public extension Sound {
    func swing(_ value: Swing) -> ModifiedSound { ModifiedSound(base: self, modifier: .swing(value)) }
    func euclidean(_ value: EuclideanRhythm) -> ModifiedSound { ModifiedSound(base: self, modifier: .euclidean(value)) }
    func ratchet(_ count: Int) -> ModifiedSound { ModifiedSound(base: self, modifier: .ratchet(count)) }
    func probability(_ value: Probability) -> ModifiedSound { ModifiedSound(base: self, modifier: .probability(value)) }
    func humanize(_ value: Humanization) -> ModifiedSound { ModifiedSound(base: self, modifier: .humanize(value)) }
    func periodically(_ value: PeriodicRhythmTransform) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .periodically(value))
    }

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
