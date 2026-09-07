internal struct _SoundCompilationContext {
    let limits: SoundCompiler.Limits
    var capturesLiveProgram = false
    var sources: [CompiledSource] = []
    var tracks: [CompiledTrack] = []
    var nodes: [CompiledRenderNode] = []
    var currentTrackID: Int?
    var eventCount = 0

    mutating func visit(_ sound: any Sound, depth: Int) throws -> _SoundFragment {
        guard depth <= limits.maximumDepth else {
            throw SoundCompilationError.maximumDepthExceeded(limit: limits.maximumDepth)
        }
        if let primitive = sound as? any _SoundPrimitive {
            return try visit(primitive._node, depth: depth)
        }
        let next = try childDepth(depth)
        return try visit(sound.body, depth: next)
    }

    private mutating func visit(_ node: _SoundNode, depth: Int) throws -> _SoundFragment {
        switch node {
        case .sample(let name):
            try validateName(name)
            return try source(.sample(name), pitch: nil)
        case .fileSample(let fileURL, let rootPitch):
            return try source(.fileSample(fileURL: fileURL, rootPitch: rootPitch), pitch: .middleC)
        case .sampleBank(let bank):
            return try source(.sampleBank(bank), pitch: .middleC, sampleKey: bank.firstKey)
        case .synthesizer(let waveform):
            return try source(.synthesizer(waveform), pitch: .middleC)
        case .group(let children):
            var result = _SoundFragment()
            var programs: [_LiveEventProgram] = []
            for child in children {
                let fragment = try visit(child, depth: childDepth(depth))
                result.events.append(contentsOf: fragment.events)
                result.roots.append(contentsOf: fragment.roots)
                result.extent = max(result.extent, fragment.extent)
                if let program = fragment.liveProgram { programs.append(program) }
            }
            result.roots = try mixedRoots(result.roots)
            if capturesLiveProgram { result.liveProgram = try .group(programs) }
            return result
        case .track(let name, let content):
            guard tracks.count < limits.maximumTracks else {
                throw SoundCompilationError.maximumTracksExceeded(limit: limits.maximumTracks)
            }
            let id = tracks.count
            tracks.append(CompiledTrack(id: id, name: name, parentID: currentTrackID))
            let previous = currentTrackID
            currentTrackID = id
            defer { currentTrackID = previous }
            return try visit(content, depth: childDepth(depth))
        case .modified(let content, let modifier):
            let firstSource = sources.count
            var fragment = try visit(content, depth: childDepth(depth))
            let childProgram = fragment.liveProgram
            try apply(modifier, to: &fragment, sourceRange: firstSource..<sources.count)
            if let childProgram {
                fragment.liveProgram = try childProgram.applying(modifier, finite: fragment)
            }
            return fragment
        }
    }

    private mutating func source(
        _ kind: SourceKind,
        pitch: Pitch?,
        sampleKey: String? = nil
    ) throws -> _SoundFragment {
        guard sources.count < limits.maximumSources else {
            throw SoundCompilationError.maximumSourcesExceeded(limit: limits.maximumSources)
        }
        try replaceEventCount(0, with: 1)
        let id = sources.count
        sources.append(CompiledSource(
            id: id, kind: kind, tuning: nil, envelope: nil, sampleRegion: nil, unison: nil
        ))
        let root = try appendNode(.source(sourceID: id))
        var fragment = _SoundFragment(
            events: [CompiledSoundEvent(
                sourceID: id, trackID: currentTrackID, start: .zero,
                duration: .quarter, pitch: pitch, velocity: 80, gate: 1,
                sampleKey: sampleKey
            )],
            roots: [root], extent: .quarter
        )
        if capturesLiveProgram { fragment.liveProgram = .finite(fragment) }
        return fragment
    }

    private mutating func apply(
        _ modifier: _SoundModifier,
        to fragment: inout _SoundFragment,
        sourceRange: Range<Int>,
        sourceIDs: Set<Int>? = nil
    ) throws {
        switch modifier {
        case .oneShot:
            break
        case .rhythm(let pattern, let cycle, let anchor):
            guard cycle > .zero else { throw invalid("Rhythm cycle must be positive") }
            do {
                let resolved = try pattern.resolvedTransform(cycle: cycle)
                let leaves = resolved.program.leaves
                let period = try resolved.period
                applyPatternProvenance(anchor, text: pattern.rawValue, to: sourceRange)
                let hitCount = leaves.reduce(0) { $0 + ($1.token == "x" ? 1 : 0) }
                let count = try expandedCount(fragment.events.count, multiplier: hitCount)
                try replaceEventCount(fragment.events.count, with: count)
                var events: [CompiledSoundEvent] = []
                events.reserveCapacity(count)
                for leaf in leaves where leaf.token == "x" {
                    let start = try _scalePatternTime(period, by: leaf.start)
                    let duration = try _scalePatternTime(period, by: leaf.duration)
                    for original in fragment.events {
                        var event = original
                        event.start = try original.start.adding(start)
                        event.duration = duration
                        event.patternStepIndex = leaf.index
                        events.append(event)
                    }
                }
                fragment.events = events
                fragment.extent = try extent(events, minimum: period)
            } catch is MusicalTimeError {
                throw RhythmPatternError.timingOverflow()
            }
        case .notePattern(let pattern, let cycle, let anchor):
            guard cycle > .zero else { throw invalid("Note cycle must be positive") }
            do {
                let resolved = try pattern.resolvedTransform(cycle: cycle)
                let leaves = resolved.program.leaves
                let period = try resolved.period
                applyPatternProvenance(anchor, text: pattern.rawValue, to: sourceRange)
                let pitches = try leaves.map { leaf in
                    leaf.token == "~" ? [] : try NotePattern.pitches(from: leaf)
                }
                let hitCount = pitches.reduce(0) { $0 + $1.count }
                let count = try expandedCount(fragment.events.count, multiplier: hitCount)
                try replaceEventCount(fragment.events.count, with: count)
                var events: [CompiledSoundEvent] = []
                events.reserveCapacity(count)
                for (leafIndex, leaf) in leaves.enumerated() where leaf.token != "~" {
                    let start = try _scalePatternTime(period, by: leaf.start)
                    let duration = try _scalePatternTime(period, by: leaf.duration)
                    for pitch in pitches[leafIndex] {
                        for original in fragment.events {
                            var event = original
                            event.start = try original.start.adding(start)
                            event.duration = duration
                            event.pitch = pitch
                            try validateEffectivePitch(event)
                            event.patternStepIndex = leaf.index
                            events.append(event)
                        }
                    }
                }
                fragment.events = events
                fragment.extent = try extent(events, minimum: period)
            } catch is MusicalTimeError {
                throw NotePatternError.timingOverflow()
            }
        case .offset(let offset):
            for index in fragment.events.indices {
                fragment.events[index].start = try fragment.events[index].start.adding(offset)
            }
            fragment.extent = try fragment.extent.adding(offset)
        case .repeated(let repetitions):
            guard repetitions > 0 else { throw invalid("Repeat count must be positive") }
            let count = try expandedCount(fragment.events.count, multiplier: repetitions)
            let newExtent = try fragment.extent.multiplied(by: UInt64(repetitions))
            try replaceEventCount(fragment.events.count, with: count)
            var events: [CompiledSoundEvent] = []
            events.reserveCapacity(count)
            if !fragment.events.isEmpty {
                for iteration in 0..<repetitions {
                    let offset = try fragment.extent.multiplied(by: UInt64(iteration))
                    for original in fragment.events {
                        var event = original
                        event.start = try original.start.adding(offset)
                        events.append(event)
                    }
                }
            }
            fragment.events = events
            fragment.extent = newExtent
        case .fast(let factor):
            guard factor > 0 else { throw invalid("Speed factor must be positive") }
            for index in fragment.events.indices {
                fragment.events[index].start = try fragment.events[index].start.divided(by: factor)
                fragment.events[index].duration = try fragment.events[index].duration.divided(by: factor)
            }
            fragment.extent = try fragment.extent.divided(by: factor)
        case .slow(let factor):
            guard factor > 0 else { throw invalid("Speed factor must be positive") }
            for index in fragment.events.indices {
                fragment.events[index].start = try fragment.events[index].start.multiplied(by: factor)
                fragment.events[index].duration = try fragment.events[index].duration.multiplied(by: factor)
            }
            fragment.extent = try fragment.extent.multiplied(by: factor)
        case .notes(let pitches, let anchor):
            guard !pitches.isEmpty else { throw invalid("Notes must not be empty") }
            applyPatternProvenance(anchor, text: nil, to: sourceRange)
            for index in fragment.events.indices {
                fragment.events[index].pitch = pitches[index % pitches.count]
                try validateEffectivePitch(fragment.events[index])
                fragment.events[index].patternStepIndex = nil
            }
        case .transpose(let semitones):
            for index in fragment.events.indices {
                fragment.events[index].pitch = try transposed(fragment.events[index].pitch, by: semitones)
                try validateEffectivePitch(fragment.events[index])
            }
        case .pitchPattern(let pattern, let cycle):
            guard cycle > .zero else { throw invalid("Pitch pattern cycle must be positive") }
            let resolved = try pattern.resolvedTransform(cycle: cycle)
            let period = try resolved.period
            for index in fragment.events.indices {
                let leaf = try sampledLeaf(resolved, period: period, at: fragment.events[index].start)
                fragment.events[index].pitchOffsetSemitones += try pattern.value(at: leaf).value
                try validateEffectivePitch(fragment.events[index])
            }
        case .fixedFilter(let kind, let cutoff, let resonanceQ, let slope):
            let filter = try SourceFilter(kind: kind, resonanceQ: resonanceQ, slope: slope)
            for index in sourceRange { sources[index].filter = filter }
            for index in fragment.events.indices {
                fragment.events[index].cutoffHz = cutoff.hertz
            }
        case .cutoffPattern(let kind, let pattern, let cycle, let resonanceQ, let slope):
            guard cycle > .zero else { throw invalid("Cutoff pattern cycle must be positive") }
            let filter = try SourceFilter(kind: kind, resonanceQ: resonanceQ, slope: slope)
            let resolved = try pattern.resolvedTransform(cycle: cycle)
            let period = try resolved.period
            for index in sourceRange { sources[index].filter = filter }
            for index in fragment.events.indices {
                let leaf = try sampledLeaf(resolved, period: period, at: fragment.events[index].start)
                fragment.events[index].cutoffHz = try pattern.value(at: leaf).hertz
            }
        case .envelopePattern(let pattern, let cycle):
            guard cycle > .zero else { throw invalid("Envelope pattern cycle must be positive") }
            let resolved = try pattern.resolvedTransform(cycle: cycle)
            let period = try resolved.period
            for index in fragment.events.indices {
                let leaf = try sampledLeaf(resolved, period: period, at: fragment.events[index].start)
                fragment.events[index].envelope = try pattern.value(at: leaf)
            }
        case .sampleSelection(let pattern, let cycle):
            guard cycle > .zero else { throw invalid("Sample selection cycle must be positive") }
            let resolved = try pattern.resolvedTransform(cycle: cycle)
            let leaves = resolved.program.leaves
            let resolvedCycle = try resolved.period
            let keys = try leaves.map { try pattern.value(at: $0) }
            let affectedSources = sourceIDs ?? Set(sourceRange)
            for sourceID in affectedSources {
                guard sources.indices.contains(sourceID) else {
                    throw invalid("Sample selection source is missing")
                }
                guard case .sampleBank(let bank) = sources[sourceID].kind else {
                    throw SoundCompilationError.unsupportedSourceSetting(
                        "Sample selection requires a sample bank source"
                    )
                }
                for (index, key) in keys.enumerated() where !bank.contains(key) {
                    throw SoundCompilationError.unknownSampleKey(
                        key: key, utf8Offset: leaves[index].offset
                    )
                }
            }
            for index in fragment.events.indices {
                let eventStart = fragment.events[index].start
                guard let leafPosition = _patternLeafIndex(
                    at: eventStart, cycle: resolvedCycle, leaves: leaves
                ) else {
                    throw invalid("Sample selection phase did not resolve to a leaf")
                }
                fragment.events[index].sampleKey = keys[leafPosition]
            }
        case .chord(let chord):
            let count = try expandedCount(fragment.events.count, multiplier: chord.intervals.count)
            try replaceEventCount(fragment.events.count, with: count)
            var events: [CompiledSoundEvent] = []
            events.reserveCapacity(count)
            for original in fragment.events {
                for interval in chord.intervals {
                    var event = original
                    event.pitch = try transposed(original.pitch, by: interval)
                    try validateEffectivePitch(event)
                    events.append(event)
                }
            }
            fragment.events = events
        case .dynamic(let dynamic):
            for index in fragment.events.indices { fragment.events[index].velocity = dynamic.velocity }
        case .velocity(let velocity):
            guard (1...127).contains(velocity) else { throw invalid("Velocity must be in 1...127") }
            for index in fragment.events.indices { fragment.events[index].velocity = velocity }
        case .gate(let gate):
            try positive(gate, "Gate")
            for index in fragment.events.indices { fragment.events[index].gate = gate }
        case .staccato:
            for index in fragment.events.indices {
                let gate = fragment.events[index].gate * 0.5
                try positive(gate, "Staccato gate")
                fragment.events[index].gate = gate
            }
        case .tuning(let tuning):
            for index in sourceRange { sources[index].tuning = tuning }
        case .envelope(let envelope):
            for index in sourceRange { sources[index].envelope = envelope }
            for index in fragment.events.indices { fragment.events[index].envelope = nil }
        case .pitchEnvelope(let modulation):
            for index in sourceRange { sources[index].pitchEnvelope = modulation }
        case .filterEnvelope(let modulation):
            for index in sourceRange { sources[index].filterEnvelope = modulation }
        case .sampleRegion(let region):
            for index in sourceRange {
                guard sources.indices.contains(index) else {
                    throw invalid("Sample region source is missing")
                }
                switch sources[index].kind {
                case .fileSample, .sampleBank:
                    sources[index].sampleRegion = region
                default:
                    throw SoundCompilationError.unsupportedSourceSetting(
                        "Sample region requires a file or sample bank source"
                    )
                }
            }
        case .sampleReversed:
            for index in sourceRange {
                guard sources.indices.contains(index) else {
                    throw invalid("Sample reversal source is missing")
                }
                switch sources[index].kind {
                case .fileSample, .sampleBank:
                    sources[index].sampleReversed = true
                default:
                    throw SoundCompilationError.unsupportedSourceSetting(
                        "Sample reversal requires a file or sample bank source"
                    )
                }
            }
        case .samplePlaybackRate(let rate):
            guard rate.isFinite, rate > 0 else {
                throw SampleDescriptorError.invalidPlaybackRate(rate)
            }
            for index in sourceRange {
                guard sources.indices.contains(index) else {
                    throw invalid("Sample playback source is missing")
                }
                switch sources[index].kind {
                case .fileSample, .sampleBank:
                    sources[index].samplePlaybackRate = rate
                default:
                    throw SoundCompilationError.unsupportedSourceSetting(
                        "Sample playback rate requires a file or sample bank source"
                    )
                }
            }
        case .unison(let unison):
            for index in sourceRange {
                guard case .synthesizer = sources[index].kind else {
                    throw SoundCompilationError.unsupportedSourceSetting("Unison requires a synthesizer source")
                }
                sources[index].unison = unison
            }
        case .voicePolicy(let policy):
            try validate(policy)
            for index in sourceRange { sources[index].voicePolicy = policy }
        case .chokeGroup(let name):
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw SoundParameterError.invalidValue("chokeGroup")
            }
            for index in sourceRange { sources[index].chokeGroup = normalized }
        case .effect(let effect):
            try validate(effect)
            if let root = try processingRoot(fragment.roots) {
                fragment.roots = [try appendNode(.effect(input: root, effect: effect))]
            }
        case .gain(let gain):
            try nonnegative(gain, "Gain")
            if let root = try processingRoot(fragment.roots) {
                fragment.roots = [try appendNode(.gain(input: root, value: gain))]
            }
        case .gainPattern(let pattern, let cycle):
            guard cycle > .zero else { throw invalid("Gain pattern cycle must be positive") }
            let resolved = try pattern.resolvedTransform(cycle: cycle)
            let leaves = resolved.program.leaves
            let resolvedCycle = try resolved.period
            for index in fragment.events.indices {
                let eventStart = fragment.events[index].start
                guard let leafPosition = _patternLeafIndex(
                    at: eventStart,
                    cycle: resolvedCycle,
                    leaves: leaves
                ) else {
                    throw invalid("Gain pattern phase did not resolve to a leaf")
                }
                guard let value = Double(leaves[leafPosition].token),
                      value.isFinite, value >= 0 else {
                    throw invalid("Gain pattern value must be finite and nonnegative")
                }
                let product = fragment.events[index].gain * value
                guard product.isFinite else {
                    throw invalid("Gain pattern product must be finite")
                }
                fragment.events[index].gain = product
            }
        case .pan(let pan):
            guard pan.isFinite, (-1...1).contains(pan) else { throw invalid("Pan must be in -1...1") }
            if let root = try processingRoot(fragment.roots) {
                fragment.roots = [try appendNode(.pan(input: root, value: pan))]
            }
        case .panPattern(let pattern, let cycle):
            guard cycle > .zero else { throw invalid("Pan pattern cycle must be positive") }
            let resolved = try pattern.resolvedTransform(cycle: cycle)
            let leaves = resolved.program.leaves
            let resolvedCycle = try resolved.period
            for index in fragment.events.indices {
                let eventStart = fragment.events[index].start
                guard let leafPosition = _patternLeafIndex(
                    at: eventStart,
                    cycle: resolvedCycle,
                    leaves: leaves
                ) else {
                    throw invalid("Pan pattern phase did not resolve to a leaf")
                }
                guard let value = Double(leaves[leafPosition].token),
                      value.isFinite, (-1...1).contains(value) else {
                    throw invalid("Pan pattern value must be finite and in -1...1")
                }
                fragment.events[index].pan = value
            }
        case .muted:
            if let root = try processingRoot(fragment.roots) {
                fragment.roots = [try appendNode(.mute(input: root))]
            }
        case .send(let bus, let level):
            try validateName(bus)
            try nonnegative(level, "Send level")
            if let root = try processingRoot(fragment.roots) {
                fragment.roots = [try appendNode(.send(input: root, bus: bus, level: level))]
            }
        case .output(let bus):
            try validateName(bus)
            if let root = try processingRoot(fragment.roots) {
                fragment.roots = [try appendNode(.output(input: root, bus: bus))]
            }
        }
    }

    internal static func applyEvents(
        _ modifier: _SoundModifier,
        events: [CompiledSoundEvent],
        extent: MusicalTime,
        limits: SoundCompiler.Limits,
        sources: [CompiledSource] = [],
        sourceIDs: Set<Int>? = nil
    ) throws -> _SoundFragment {
        var context = Self(limits: limits, sources: sources)
        context.eventCount = events.count
        var fragment = _SoundFragment(events: events, extent: extent)
        try context.apply(modifier, to: &fragment, sourceRange: 0..<0, sourceIDs: sourceIDs)
        return fragment
    }

    func finishLive(_ fragment: _SoundFragment, policy: LiveLoopPolicy) throws -> CompiledSound {
        guard let program = fragment.liveProgram else {
            throw SoundCompilationError.invalidParameter("Live program was not captured")
        }
        let window = try program.window(policy: policy)
        var rendered = fragment
        rendered.events = try program.emit(through: window, limits: limits, sources: sources)
        rendered.extent = window
        let beats = Double(window.numerator) / Double(window.denominator)
        for (index, event) in rendered.events.enumerated() {
            let duration = Double(event.duration.numerator) / Double(event.duration.denominator) * event.gate
            guard duration.isFinite, duration > 0, duration <= beats else {
                throw SoundCompilationError.liveEventDurationExceeded(index: index)
            }
            guard event.start < window else {
                throw SoundCompilationError.invalidParameter("Live event starts outside its window")
            }
        }
        var result = finish(rendered)
        result.playbackMode = .seamlessLoop
        return result
    }

    private func sampledLeaf(
        _ resolved: _PatternResolvedTransform, period: MusicalTime, at start: MusicalTime
    ) throws -> _PatternTimedLeaf {
        guard let index = _patternLeafIndex(at: start, cycle: period, leaves: resolved.program.leaves) else {
            throw invalid("Parameter pattern phase did not resolve to a leaf")
        }
        return resolved.program.leaves[index]
    }

    private func validateEffectivePitch(_ event: CompiledSoundEvent) throws {
        guard let pitch = event.pitch else { throw SoundCompilationError.missingPitch }
        let effective = Double(pitch.midiNote) + event.pitchOffsetSemitones
        guard effective.isFinite, (0...127).contains(effective) else {
            throw SoundCompilationError.pitchOutOfRange
        }
    }

    private func transposed(_ pitch: Pitch?, by semitones: Int) throws -> Pitch {
        guard let pitch else { throw SoundCompilationError.missingPitch }
        let (value, overflow) = Int(pitch.midiNote).addingReportingOverflow(semitones)
        guard !overflow, (0...127).contains(value) else { throw SoundCompilationError.pitchOutOfRange }
        return try Pitch(midiNote: UInt8(value))
    }

    private mutating func applyPatternProvenance(
        _ anchor: SoundSourceAnchor,
        text: String?,
        to sourceRange: Range<Int>
    ) {
        for index in sourceRange {
            sources[index].patternAnchor = anchor
            sources[index].patternText = text
        }
    }

    private func extent(_ events: [CompiledSoundEvent], minimum: MusicalTime) throws -> MusicalTime {
        var result = minimum
        for event in events { result = max(result, try event.start.adding(event.duration)) }
        return result
    }

    private mutating func replaceEventCount(_ old: Int, with new: Int) throws {
        let retained = eventCount - old
        guard new <= limits.maximumEvents - retained else {
            throw SoundCompilationError.maximumEventsExceeded(limit: limits.maximumEvents)
        }
        eventCount = retained + new
    }

    private func expandedCount(_ count: Int, multiplier: Int) throws -> Int {
        let (result, overflow) = count.multipliedReportingOverflow(by: multiplier)
        guard !overflow, result <= limits.maximumEvents else {
            throw SoundCompilationError.maximumEventsExceeded(limit: limits.maximumEvents)
        }
        return result
    }

    private mutating func mixedRoots(_ roots: [Int]) throws -> [Int] {
        var outputs: [Int] = []
        var main: [Int] = []
        for root in roots {
            if case .output = nodes[root] { outputs.append(root) }
            else { main.append(root) }
        }
        if main.count > 1 { outputs.append(try appendNode(.mix(inputs: main))) }
        else { outputs.append(contentsOf: main) }
        return outputs
    }

    private mutating func processingRoot(_ roots: [Int]) throws -> Int? {
        for root in roots {
            if case .output = nodes[root] {
                throw invalid("Audio processing must precede output routing")
            }
        }
        return try mixedRoots(roots).first
    }

    private mutating func appendNode(_ node: CompiledRenderNode) throws -> Int {
        guard nodes.count < limits.maximumRenderNodes else {
            throw SoundCompilationError.maximumRenderNodesExceeded(limit: limits.maximumRenderNodes)
        }
        let id = nodes.count
        nodes.append(node)
        return id
    }

    private func childDepth(_ depth: Int) throws -> Int {
        guard depth < limits.maximumDepth else {
            throw SoundCompilationError.maximumDepthExceeded(limit: limits.maximumDepth)
        }
        return depth + 1
    }

    private func validateName(_ name: String) throws {
        guard name.contains(where: { !$0.isWhitespace }) else { throw invalid("Name must not be blank") }
    }

    private func invalid(_ description: String) -> SoundCompilationError {
        .invalidParameter(description)
    }

    private func positive(_ value: Double, _ name: String) throws {
        guard value.isFinite, value > 0 else { throw invalid("\(name) must be finite and positive") }
    }

    private func nonnegative(_ value: Double, _ name: String) throws {
        guard value.isFinite, value >= 0 else { throw invalid("\(name) must be finite and nonnegative") }
    }

    private func validate(_ policy: VoicePolicy) throws {
        guard case .polyphonic(let limit, _) = policy else { return }
        guard (1...limits.maximumEvents).contains(limit) else {
            throw SoundParameterError.invalidVoices
        }
    }

    private func normalized(_ value: Double, _ name: String) throws {
        guard value.isFinite, (0...1).contains(value) else { throw invalid("\(name) must be in 0...1") }
    }

    private func validate(_ effect: AudioEffect) throws {
        switch effect {
        case .equalizer(let frequency, let gain, let q):
            try positive(frequency, "EQ frequency")
            try positive(q, "EQ Q")
            guard gain.isFinite else { throw invalid("EQ gain must be finite") }
        case .filter(_, let cutoff, let resonance):
            try positive(cutoff, "Filter cutoff")
            try nonnegative(resonance, "Filter resonance")
        case .compressor(let threshold, let ratio):
            guard threshold.isFinite else { throw invalid("Compressor threshold must be finite") }
            guard ratio.isFinite, ratio >= 1 else { throw invalid("Compressor ratio must be at least one") }
        case .saturation(let drive):
            try nonnegative(drive, "Saturation drive")
        case .distortion(let drive):
            try nonnegative(drive, "Distortion drive")
        case .delay(let time, let feedback, let wet):
            guard time > .zero else { throw invalid("Delay time must be positive") }
            guard feedback.isFinite, (0..<1).contains(feedback) else { throw invalid("Feedback must be in 0..<1") }
            try normalized(wet, "Delay wet")
        case .reverb(let roomSize, let wet):
            try normalized(roomSize, "Reverb room size")
            try normalized(wet, "Reverb wet")
        case .chorus(let rate, let depth, let wet):
            try positive(rate, "Chorus rate")
            try normalized(depth, "Chorus depth")
            try normalized(wet, "Chorus wet")
        }
    }

    func finish(_ fragment: _SoundFragment) -> CompiledSound {
        let events = fragment.events.enumerated().sorted {
            if $0.element.start != $1.element.start { return $0.element.start < $1.element.start }
            return $0.offset < $1.offset
        }.map(\.element)
        return CompiledSound(
            events: events, tracks: tracks, sources: sources, renderNodes: nodes,
            rootNodeIDs: fragment.roots, extent: fragment.extent
        )
    }
}
