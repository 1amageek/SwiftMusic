/// Ordered harmony transformations over compiler-owned event values.
internal enum _HarmonyEventProcessing {
    struct Group: Hashable {
        let source: Int
        let group: Int
        let occurrence: Int
    }

    static func effective(_ event: CompiledSoundEvent) throws -> Double {
        guard let pitch = event.pitch else { throw SoundCompilationError.missingPitch }
        let value = Double(pitch.midiNote) + event.pitchOffsetSemitones
        guard value.isFinite, (0...127).contains(value) else { throw SoundCompilationError.pitchOutOfRange }
        return value
    }

    static func groups(_ events: [CompiledSoundEvent]) throws -> [[Int]] {
        var positions: [Group: Int] = [:]
        var result: [[Int]] = []
        for (index, event) in events.enumerated() {
            guard let group = event.harmonyGroupID, let occurrence = event.harmonyOccurrenceID else {
                throw HarmonyError.missingHarmony
            }
            let key = Group(source: event.sourceID, group: group, occurrence: occurrence)
            if let position = positions[key] { result[position].append(index) }
            else { positions[key] = result.count; result.append([index]) }
        }
        return result
    }

    static func apply(_ modifier: _SoundModifier, events: [CompiledSoundEvent], extent: MusicalTime,
                      maximumEvents: Int) throws -> _SoundFragment {
        var output = events
        var end = extent
        switch modifier {
        case .scaleNotes(let degrees, let key, _):
            guard !degrees.isEmpty else { throw SoundParameterError.invalidValue("scale degrees") }
            for index in output.indices {
                let (degree, overflow) = degrees[index % degrees.count].value.subtractingReportingOverflow(1)
                guard !overflow else { throw SoundCompilationError.pitchOutOfRange }
                let count = key.scale.intervals.count
                let remainder = degree % count
                let member = remainder < 0 ? remainder + count : remainder
                let octave = degree / count - (remainder < 0 ? 1 : 0)
                output[index].pitch = key.tonic
                output[index].pitchOffsetSemitones += Double(octave) * 12 + key.scale.intervals[member].value
                output[index].patternStepIndex = nil
                _ = try effective(output[index])
            }
        case .voicing(let value):
            for group in try groups(output) {
                let ordered = group.sorted { (output[$0].harmonyVoiceIndex ?? 0) < (output[$1].harmonyVoiceIndex ?? 0) }
                for index in ordered {
                    let voice = output[index].harmonyVoiceIndex ?? 0
                    output[index].pitchOffsetSemitones += Double(value.octaveOffsets[voice % value.octaveOffsets.count]) * 12
                    _ = try effective(output[index])
                }
            }
        case .inversion(let count):
            guard (-16...16).contains(count) else { throw SoundParameterError.invalidValue("inversion") }
            for group in try groups(output) {
                for _ in 0..<abs(count) {
                    var selected = group[0]
                    for index in group.dropFirst() {
                        let pitch = try effective(output[index])
                        let current = try effective(output[selected])
                        if count > 0 ? pitch < current : pitch > current { selected = index }
                    }
                    let voice = output[selected].harmonyVoiceIndex
                    for index in group where output[index].harmonyVoiceIndex == voice {
                        output[index].pitchOffsetSemitones += count > 0 ? 12 : -12
                        _ = try effective(output[index])
                    }
                }
            }
        case .arpeggio(let value):
            let groups = try groups(events)
            var sequences: [[Int]] = []
            var count = 0
            var rules = 0
            for group in groups {
                var ordered = try group.sorted {
                    let left = try effective(events[$0]), right = try effective(events[$1])
                    if left != right { return left < right }
                    return (events[$0].harmonyVoiceIndex ?? 0) < (events[$1].harmonyVoiceIndex ?? 0)
                }
                switch value.order {
                case .asDeclared: ordered = group.sorted { (events[$0].harmonyVoiceIndex ?? 0) < (events[$1].harmonyVoiceIndex ?? 0) }
                case .up: break
                case .down: ordered.reverse()
                case .upDown:
                    if ordered.count > 2 { ordered.append(contentsOf: ordered.dropFirst().dropLast().reversed()) }
                }
                guard ordered.count <= maximumEvents - count else {
                    throw SoundCompilationError.maximumEventsExceeded(limit: maximumEvents)
                }
                count += ordered.count
                for index in ordered {
                    guard events[index].pendingEventDucks.count <= 1_024 - rules else {
                        throw SoundParameterError.invalidValue("event duck rule count")
                    }
                    rules += events[index].pendingEventDucks.count
                }
                sequences.append(ordered)
            }
            output = []
            output.reserveCapacity(count)
            for sequence in sequences {
                for (position, index) in sequence.enumerated() {
                    var event = events[index]
                    event.start = try event.start.adding(value.step.multiplied(by: UInt64(position)))
                    end = max(end, try event.start.adding(event.duration))
                    output.append(event)
                }
            }
        default: preconditionFailure("Only harmony transforms enter this processor")
        }
        return _SoundFragment(events: output, extent: end)
    }

    /// Resolves final lane neighbors once, after pitch modifiers and stable onset sorting.
    static func connect(_ events: inout [CompiledSoundEvent], sources: [CompiledSource],
                        extent: MusicalTime, recurringSources: Set<Int>) throws {
        guard events.contains(where: { $0.legato != nil }) || sources.contains(where: { $0.portamento != nil }) else { return }
        struct Lane: Hashable { let source: Int; let voice: Int }
        var lanes: [Lane: [Int]] = [:]
        for (index, event) in events.enumerated() {
            lanes[Lane(source: event.sourceID, voice: event.harmonyVoiceIndex ?? 0), default: []].append(index)
        }
        for lane in lanes.values {
            // Equal-onset voices cannot become each other's temporal predecessor.
            var clusters: [[Int]] = []
            for index in lane {
                if let last = clusters.last, events[last[0]].start == events[index].start {
                    clusters[clusters.count - 1].append(index)
                } else { clusters.append([index]) }
            }
            for position in clusters.indices {
                let cluster = clusters[position]
                for index in cluster {
                    let recurring = recurringSources.contains(events[index].sourceID)
                    if let legato = events[index].legato {
                        let next: MusicalTime?
                        if position + 1 < clusters.count { next = events[clusters[position + 1][0]].start }
                        else if recurring { next = try events[clusters[0][0]].start.adding(extent) }
                        else { next = nil }
                        if let next {
                            let length = try _subtractPatternTime(next.adding(legato.overlap), events[index].start)
                            let gate = (Double(length.numerator) / Double(length.denominator))
                                / (Double(events[index].duration.numerator) / Double(events[index].duration.denominator))
                            guard gate.isFinite, gate > 0 else { throw SoundParameterError.invalidValue("legato gate") }
                            events[index].gate = gate
                        }
                    }
                    if sources[events[index].sourceID].portamento != nil {
                        let predecessor: Int?
                        if position > 0 { predecessor = clusters[position - 1].last }
                        else if recurring { predecessor = clusters.last?.last }
                        else { predecessor = nil }
                        events[index].portamentoStartMIDINote = try predecessor.map { try effective(events[$0]) }
                        _ = try effective(events[index])
                    }
                }
            }
        }
    }
}
