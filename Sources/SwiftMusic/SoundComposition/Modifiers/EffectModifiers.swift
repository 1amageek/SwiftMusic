public extension Sound {
    func effect(_ value: AudioEffect) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .effect(value))
    }

    func tremolo(
        rate: ModulationRate,
        depth: Double,
        waveform: LFOWaveform = .sine
    ) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .tremolo(rate, depth, waveform))
    }

    func vibrato(
        rate: ModulationRate,
        depth: Semitones,
        waveform: LFOWaveform = .sine
    ) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .vibrato(rate, depth, waveform))
    }
}
