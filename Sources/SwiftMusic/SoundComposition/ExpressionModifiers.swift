public extension Sound {
    func dynamic(_ value: Dynamic) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .dynamic(value))
    }

    func velocity(_ value: Int) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .velocity(value))
    }

    func gate(_ value: Double) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .gate(value))
    }

    func legato(_ value: Legato = Legato()) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .legato(value))
    }

    func staccato() -> ModifiedSound {
        ModifiedSound(base: self, modifier: .staccato)
    }
}
