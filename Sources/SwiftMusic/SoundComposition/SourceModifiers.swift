public extension Sound {
    func tuning(_ value: Tuning) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .tuning(value))
    }

    func envelope(_ value: Envelope) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .envelope(value))
    }

    func envelope(_ pattern: EnvelopePattern, cycle: MusicalTime = .whole) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .envelopePattern(pattern, cycle))
    }

    func lowPass(
        _ pattern: CutoffPattern,
        cycle: MusicalTime = .whole,
        resonanceQ: Double = 0.7071067811865476,
        slope: FilterSlope = .twelve
    ) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .cutoffPattern(pattern, cycle, resonanceQ, slope))
    }

    func sampleRegion(_ value: SampleRegion) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .sampleRegion(value))
    }

    func unison(_ value: Unison) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .unison(value))
    }
}
