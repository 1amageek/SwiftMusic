import Foundation

internal indirect enum _SoundNode: Sendable {
    case group([any Sound])
    case sample(String)
    case fileSample(fileURL: URL, rootPitch: Pitch)
    case sampleBank(SampleBank)
    case synthesizer(Waveform)
    case track(Track)
    case modified(any Sound, _SoundModifier)
}
