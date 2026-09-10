/// A positive duration for pitch glides between adjacent events.
public struct Portamento: Sendable, Equatable, Hashable {
    public let duration: PortamentoDuration

    /// Creates a portamento descriptor with a finite positive duration.
    public init(duration: PortamentoDuration) throws {
        switch duration {
        case .seconds(let value):
            guard value > .zero else {
                throw HarmonyError.invalidPortamento
            }
            let parts = value.components
            let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            guard seconds.isFinite, seconds > 0 else {
                throw HarmonyError.invalidPortamento
            }
        case .beats(let value):
            guard value > .zero else {
                throw HarmonyError.invalidPortamento
            }
        }
        self.duration = duration
    }
}
