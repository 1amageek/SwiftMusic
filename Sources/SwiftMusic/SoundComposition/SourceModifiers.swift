public extension Sound {
    func tuning(_ value: Tuning) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .tuning(value))
    }

    func envelope(_ value: Envelope) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .envelope(value))
    }

    func sampleRegion(_ value: SampleRegion) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .sampleRegion(value))
    }

    func unison(_ value: Unison) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .unison(value))
    }
}
