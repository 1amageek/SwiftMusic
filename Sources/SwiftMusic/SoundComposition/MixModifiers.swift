public extension Sound {
    func gain(_ value: Double) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .gain(value))
    }

    func gain(_ pattern: GainPattern, cycle: MusicalTime = .whole) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .gainPattern(pattern, cycle))
    }

    func gain(_ automation: GainAutomation) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .gainAutomation(automation))
    }

    func pan(_ value: Double) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .pan(value))
    }

    func pan(_ pattern: PanPattern, cycle: MusicalTime = .whole) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .panPattern(pattern, cycle))
    }

    func pan(_ automation: PanAutomation) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .panAutomation(automation))
    }

    func duck(
        targetBus: String,
        depth: Decibels,
        attack: Duration,
        recovery: Duration
    ) -> ModifiedSound {
        ModifiedSound(
            base: self,
            modifier: .duck(targetBus, depth, attack, recovery)
        )
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
