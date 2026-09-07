internal indirect enum _SoundNode: Sendable {
    case group([any Sound])
    case sample(String)
    case synthesizer(Waveform)
    case track(String, any Sound)
    case modified(any Sound, _SoundModifier)
}
