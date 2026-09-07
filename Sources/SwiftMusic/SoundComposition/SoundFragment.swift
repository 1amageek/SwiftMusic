internal struct _SoundFragment {
    var events: [CompiledSoundEvent] = []
    var roots: [Int] = []
    var extent: MusicalTime = .zero
}
