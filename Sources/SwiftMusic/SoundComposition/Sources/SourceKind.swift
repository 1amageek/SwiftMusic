import Foundation

public enum SourceKind: Sendable, Equatable, Hashable {
    case sample(String)
    case fileSample(fileURL: URL, rootPitch: Pitch)
    case sampleBank(SampleBank)
    case synthesizer(Waveform)
}
