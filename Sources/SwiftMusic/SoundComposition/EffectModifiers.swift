public extension Sound {
    func effect(_ value: AudioEffect) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .effect(value))
    }
}
