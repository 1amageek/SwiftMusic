public struct Unison: Sendable, Equatable, Hashable {
    public let voices: Int
    public let detuneCents: Double

    public init(voices: Int, detuneCents: Double) throws {
        guard (1...16).contains(voices) else {
            throw SoundParameterError.invalidVoices
        }
        guard detuneCents.isFinite, detuneCents >= 0 else {
            throw SoundParameterError.invalidValue("detuneCents")
        }
        self.voices = voices
        self.detuneCents = detuneCents
    }
}
