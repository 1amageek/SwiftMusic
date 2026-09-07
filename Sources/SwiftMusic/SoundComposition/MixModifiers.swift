public extension Sound {
    func gain(_ value: Double) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .gain(value))
    }

    func gain(_ pattern: GainPattern, cycle: MusicalTime = .whole) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .gainPattern(pattern, cycle))
    }

    func pan(_ value: Double) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .pan(value))
    }

    func muted() -> ModifiedSound {
        ModifiedSound(base: self, modifier: .muted)
    }

    func send(to bus: String, level: Double) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .send(bus, level))
    }

    func output(_ bus: String) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .output(bus))
    }
}
