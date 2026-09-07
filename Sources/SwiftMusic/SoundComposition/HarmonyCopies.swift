/// Gives each copied chord occurrence independent identity while preserving its voices.
internal struct _HarmonyCopies {
    private struct Key: Hashable {
        let source: Int
        let group: Int
        let occurrence: Int
        let copy: Int
    }
    private var identifiers: [Key: Int] = [:]
    private var next: Int

    init(_ events: [CompiledSoundEvent]) {
        next = (events.lazy.compactMap(\.harmonyOccurrenceID).max() ?? -1) + 1
    }

    mutating func copy(_ original: CompiledSoundEvent, iteration: Int) -> CompiledSoundEvent {
        guard let group = original.harmonyGroupID, let occurrence = original.harmonyOccurrenceID else { return original }
        let key = Key(source: original.sourceID, group: group, occurrence: occurrence, copy: iteration)
        let id: Int
        if let existing = identifiers[key] { id = existing }
        else { id = next; next += 1; identifiers[key] = id }
        var event = original
        event.harmonyOccurrenceID = id
        return event
    }
}
