internal struct _SoundCompilationContext {
    let limits: SoundCompiler.Limits
    var capturesLiveProgram = false
    var eventTransformPeriod: MusicalTime?
    var sources: [CompiledSource] = []
    var tracks: [CompiledTrack] = []
    var nodes: [CompiledRenderNode] = []
    var sidechainBuses: [Int: String] = [:]
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
        case .busReturn(let name):
            try validateBusName(name)
            let root = try appendNode(.busReturn(bus: name, inputs: []))
            var fragment = _SoundFragment(roots: [root])
            if capturesLiveProgram { fragment.liveProgram = .finite(fragment) }
            return fragment
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
        case .track(let track):
            guard tracks.count < limits.maximumTracks else {
                throw SoundCompilationError.maximumTracksExceeded(limit: limits.maximumTracks)
            }
            try validate(track)
            let id = tracks.count
            tracks.append(CompiledTrack(
                id: id,
                name: track.name,
                parentID: currentTrackID,
                level: track.level,
                pan: track.pan,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed
            ))
            let previous = currentTrackID
            currentTrackID = id
            let fragment: _SoundFragment
            do {
                fragment = try visit(track.content, depth: childDepth(depth))
            } catch {
                currentTrackID = previous
                throw error
            }
            currentTrackID = previous

            let outputRoots = fragment.roots.filter { root in
                if case .output = nodes[root] { return true }
                return false
            }
            let mainRoots = fragment.roots.filter { root in
                if case .output = nodes[root] { return false }
                return true
            }
            let hasNondefaultSettings = track.level != 1
                || track.pan != nil
                || track.isMuted
                || track.isSoloed
                || !track.sends.isEmpty
            for send in track.sends {
                try validateBusName(send.bus)
                try nonnegative(send.level, "Track send level")
            }
            if hasNondefaultSettings, !outputRoots.isEmpty {
                throw invalid("Audio processing must precede output routing")
            }
            guard !mainRoots.isEmpty else {
                return fragment
            }
            let mainRoot: Int
            if mainRoots.count == 1 {
                mainRoot = mainRoots[0]
            } else {
                mainRoot = try appendNode(.mix(inputs: mainRoots))
            }
            let trackRoot = try appendNode(.track(input: mainRoot, trackID: id))
            tracks[id].renderNodeID = trackRoot
            for send in track.sends {
                let input: Int
                switch send.placement {
                case .preFader:
                    input = mainRoot
                case .postFader:
                    input = trackRoot
                }
                _ = try appendNode(.trackSend(
                    input: input,
                    bus: send.bus,
                    level: send.level,
                    trackID: id,
                    placement: send.placement
                ))
            }
            var result = fragment
            result.roots = outputRoots + [trackRoot]
            return result
        case .modified(let content, let modifier):
            let firstSource = sources.count
            var modifiers: [_SoundModifier] = [modifier]
            var base: any Sound = content
            var baseDepth = try childDepth(depth)

            // Peel only contiguous modifier wrappers so a long modifier chain cannot consume
            // the task stack. The depth guard remains applied once per wrapper.
            while let primitive = base as? any _SoundPrimitive {
                guard case .modified(let next, let nextModifier) = primitive._node else {
                    break
                }
                modifiers.append(nextModifier)
                base = next
                baseDepth = try childDepth(baseDepth)
            }

            var fragment = try visit(base, depth: baseDepth)
            for modifier in modifiers.reversed() {
                let childProgram = fragment.liveProgram
                try apply(modifier, to: &fragment, sourceRange: firstSource..<sources.count)
                if let childProgram {
                    fragment.liveProgram = try childProgram.applying(modifier, finite: fragment)
                }
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
        case .swing, .euclidean, .ratchet, .probability, .humanize, .periodically:
            var period = eventTransformPeriod ?? (capturesLiveProgram ? fragment.liveProgram?.period : nil)
            do {
                if period != nil {
                    switch modifier {
                    case .swing(let value): period = try _LiveEventProgram.commonPeriod(period, value.subdivision.multiplied(by: 2))
                    case .euclidean(let value): period = try _LiveEventProgram.commonPeriod(period, value.cycle)
                    case .periodically(let value): period = try _LiveEventProgram.commonPeriod(period, value.cycle.multiplied(by: value.every))
                    default: break
                    }
                }
            } catch is MusicalTimeError { throw RhythmTransformError.timingOverflow }
            let result = try _RhythmEventProcessing.apply(modifier, events: fragment.events,
                extent: fragment.extent, limits: limits, livePeriod: period,
                maximumOutputEvents: limits.maximumEvents - eventCount + fragment.events.count)
            try replaceEventCount(fragment.events.count, with: result.events.count)
            fragment.events = result.events
            fragment.extent = result.extent
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
                try Self.validateEventDuckRuleBudget(fragment.events, copies: hitCount)
                try replaceEventCount(fragment.events.count, with: count)
                var events: [CompiledSoundEvent] = []
                events.reserveCapacity(count)
                var harmonyCopies = _HarmonyCopies(fragment.events)
                for (leafOrdinal, leaf) in leaves.enumerated() where leaf.token == "x" {
                    let start = try _scalePatternTime(period, by: leaf.start)
                    let duration = try _scalePatternTime(period, by: leaf.duration)
                    for original in fragment.events {
                        var event = harmonyCopies.copy(original, iteration: leafOrdinal)
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
                try Self.validateEventDuckRuleBudget(fragment.events, copies: hitCount)
                try replaceEventCount(fragment.events.count, with: count)
                var events: [CompiledSoundEvent] = []
                events.reserveCapacity(count)
                var nextHarmonyGroup = (fragment.events.lazy.compactMap(\.harmonyGroupID).max() ?? -1) + 1
                var noteCopies = _HarmonyCopies(fragment.events)
                for (leafIndex, leaf) in leaves.enumerated() where leaf.token != "~" {
                    let start = try _scalePatternTime(period, by: leaf.start)
                    let duration = try _scalePatternTime(period, by: leaf.duration)
                    let groupBase = nextHarmonyGroup
                    nextHarmonyGroup += fragment.events.count
                    for (voice, pitch) in pitches[leafIndex].enumerated() {
                        for (originalIndex, original) in fragment.events.enumerated() {
                            var event = noteCopies.copy(original, iteration: leafIndex)
                            event.start = try original.start.adding(start)
                            event.duration = duration
                            event.pitch = pitch
                            if pitches[leafIndex].count > 1 {
                                event.harmonyGroupID = groupBase + originalIndex
                                event.harmonyOccurrenceID = groupBase + originalIndex
                                event.harmonyVoiceIndex = voice
                            }
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
            try Self.validateEventDuckRuleBudget(fragment.events, copies: repetitions)
            let newExtent = try fragment.extent.multiplied(by: UInt64(repetitions))
            try replaceEventCount(fragment.events.count, with: count)
            var events: [CompiledSoundEvent] = []
            events.reserveCapacity(count)
            var harmonyCopies = _HarmonyCopies(fragment.events)
            if !fragment.events.isEmpty {
                for iteration in 0..<repetitions {
                    let offset = try fragment.extent.multiplied(by: UInt64(iteration))
                    for original in fragment.events {
                        var event = harmonyCopies.copy(original, iteration: iteration)
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
        case .pitchAutomation(let automation):
            guard !sourceRange.isEmpty else {
                throw invalid("Pitch automation requires a source")
            }
            try validate(automation, events: fragment.events, sourceRange: sourceRange)
            for index in sourceRange {
                guard sources.indices.contains(index) else { throw invalid("Pitch automation source is missing") }
                switch sources[index].kind {
                case .synthesizer(let waveform):
                    guard waveform != .noise else {
                        throw SoundCompilationError.unsupportedSourceSetting(
                            "Pitch automation requires a pitched source"
                        )
                    }
                    sources[index].pitchAutomation = automation
                case .fileSample, .sampleBank:
                    sources[index].pitchAutomation = automation
                case .sample:
                    throw SoundCompilationError.unsupportedSourceSetting(
                        "Pitch automation requires a pitched source"
                    )
                }
            }
        case .fixedFilter(let kind, let cutoff, let resonanceQ, let slope):
            let filter = try SourceFilter(kind: kind, resonanceQ: resonanceQ, slope: slope)
            for index in sourceRange {
                sources[index].filter = filter
                sources[index].cutoffAutomation = nil
            }
            for index in fragment.events.indices {
                fragment.events[index].cutoffHz = cutoff.hertz
            }
        case .cutoffPattern(let kind, let pattern, let cycle, let resonanceQ, let slope):
            guard cycle > .zero else { throw invalid("Cutoff pattern cycle must be positive") }
            let filter = try SourceFilter(kind: kind, resonanceQ: resonanceQ, slope: slope)
            let resolved = try pattern.resolvedTransform(cycle: cycle)
            let period = try resolved.period
            for index in sourceRange {
                sources[index].filter = filter
                sources[index].cutoffAutomation = nil
            }
            for index in fragment.events.indices {
                let leaf = try sampledLeaf(resolved, period: period, at: fragment.events[index].start)
                fragment.events[index].cutoffHz = try pattern.value(at: leaf).hertz
            }
        case .cutoffAutomation(let kind, let automation, let resonanceQ, let slope):
            guard !sourceRange.isEmpty else {
                throw invalid("Cutoff automation requires a source")
            }
            let filter = try SourceFilter(kind: kind, resonanceQ: resonanceQ, slope: slope)
            for index in sourceRange {
                guard sources.indices.contains(index) else { throw invalid("Cutoff automation source is missing") }
                sources[index].filter = filter
                sources[index].cutoffAutomation = automation
            }
            for index in fragment.events.indices {
                fragment.events[index].cutoffHz = automation.from.hertz
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
        case .scaleNotes, .voicing, .inversion, .arpeggio:
            if case .scaleNotes(_, _, let anchor) = modifier {
                applyPatternProvenance(anchor, text: nil, to: sourceRange)
            }
            let result = try _HarmonyEventProcessing.apply(modifier, events: fragment.events,
                extent: fragment.extent, maximumEvents: limits.maximumEvents - eventCount + fragment.events.count)
            try replaceEventCount(fragment.events.count, with: result.events.count)
            fragment.events = result.events
            fragment.extent = result.extent
        case .legato(let value):
            for index in fragment.events.indices { fragment.events[index].legato = value }
        case .portamento(let value):
            guard !sourceRange.isEmpty else { throw invalid("Portamento requires a source") }
            for index in sourceRange {
                switch sources[index].kind {
                case .sample, .synthesizer(.noise): throw invalid("Portamento requires a pitched source")
                default: break
                }
                sources[index].portamento = value
            }
        case .chord(let chord):
            let count = try expandedCount(fragment.events.count, multiplier: chord.intervals.count)
            try Self.validateEventDuckRuleBudget(fragment.events, copies: chord.intervals.count)
            try replaceEventCount(fragment.events.count, with: count)
            var events: [CompiledSoundEvent] = []
            events.reserveCapacity(count)
            var group = (fragment.events.lazy.compactMap(\.harmonyGroupID).max() ?? -1) + 1
            for original in fragment.events {
                for (voice, interval) in chord.intervals.enumerated() {
                    var event = original
                    let integral = interval.value.rounded(.towardZero)
                    guard (-127...127).contains(integral) else { throw SoundCompilationError.pitchOutOfRange }
                    event.pitch = try transposed(original.pitch, by: Int(integral))
                    event.pitchOffsetSemitones += interval.value - integral
                    event.harmonyGroupID = group
                    event.harmonyOccurrenceID = group
                    event.harmonyVoiceIndex = voice
                    try validateEffectivePitch(event)
                    events.append(event)
                }
                group += 1
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
                if case .sidechainCompressor(let compressor) = effect,
                   let sidechainBus = compressor.sidechainBus {
                    let node = try appendNode(
                        .sidechainEffect(input: root, sidechain: -1, compressor: compressor)
                    )
                    sidechainBuses[node] = sidechainBus
                    fragment.roots = [node]
                } else {
                    fragment.roots = [try appendNode(.effect(input: root, effect: effect))]
                }
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
        case .gainAutomation(let automation):
            if let root = try processingRoot(fragment.roots) {
                fragment.roots = [try appendNode(.gainAutomation(input: root, automation: automation))]
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
        case .panAutomation(let automation):
            if let root = try processingRoot(fragment.roots) {
                fragment.roots = [try appendNode(.panAutomation(input: root, automation: automation))]
            }
        case .duck(let targetBus, let depth, let attack, let recovery):
            try validateBusName(targetBus)
            let attackSeconds = try _dynamicsDurationSeconds(attack)
            let recoverySeconds = try _dynamicsDurationSeconds(recovery)
            guard depth.value <= 0 else {
                throw invalid("Duck depth must be finite and nonpositive")
            }
            guard recoverySeconds > 0 else {
                throw invalid("Duck recovery must be finite and positive")
            }
            let pending = _PendingEventDuck(
                targetBus: targetBus,
                depthDecibels: depth.value,
                attackSeconds: attackSeconds,
                recoverySeconds: recoverySeconds
            )
            try Self.validateEventDuckRuleBudget(fragment.events, additionalPerEvent: 1)
            for index in fragment.events.indices {
                fragment.events[index].pendingEventDucks.append(pending)
            }
        case .muted:
            if let root = try processingRoot(fragment.roots) {
                fragment.roots = [try appendNode(.mute(input: root))]
            }
        case .send(let bus, let level):
            try validateBusName(bus)
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
        sourceIDs: Set<Int>? = nil,
        livePeriod: MusicalTime? = nil
    ) throws -> _SoundFragment {
        var context = Self(limits: limits, eventTransformPeriod: livePeriod, sources: sources)
        context.eventCount = events.count
        var fragment = _SoundFragment(events: events, extent: extent)
        try context.apply(modifier, to: &fragment, sourceRange: 0..<0, sourceIDs: sourceIDs)
        return fragment
    }

    func finishLive(_ fragment: _SoundFragment, policy: LiveLoopPolicy) throws -> CompiledSound {
        guard let program = fragment.liveProgram else {
            throw SoundCompilationError.invalidParameter("Live program was not captured")
        }
        let automationPeriod = try continuousAutomationPeriod()
        let window = try program.window(policy: policy, additionalPeriod: automationPeriod)
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
        var result = try finish(rendered, recurringSources: program.recurringSourceIDs)
        result.playbackMode = .seamlessLoop
        return result
    }

    private func continuousAutomationPeriod() throws -> MusicalTime? {
        var result: MusicalTime?
        for source in sources {
            result = try _LiveEventProgram.commonPeriod(
                result, source.pitchAutomation?.synchronizedPeriod
            )
            result = try _LiveEventProgram.commonPeriod(
                result, source.cutoffAutomation?.synchronizedPeriod
            )
        }
        for node in nodes {
            switch node {
            case .gainAutomation(_, let automation):
                result = try _LiveEventProgram.commonPeriod(result, automation.synchronizedPeriod)
            case .panAutomation(_, let automation):
                result = try _LiveEventProgram.commonPeriod(result, automation.synchronizedPeriod)
            default:
                break
            }
        }
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
        let base = Double(pitch.midiNote) + event.pitchOffsetSemitones
        guard base.isFinite, (0...127).contains(base) else {
            throw SoundCompilationError.pitchOutOfRange
        }
    }

    private func validateRetainedPitchAutomation(_ event: CompiledSoundEvent) throws {
        guard sources.indices.contains(event.sourceID) else {
            throw SoundCompilationError.invalidParameter("Pitch source is missing")
        }
        guard let automation = sources[event.sourceID].pitchAutomation else { return }
        guard let pitch = event.pitch else { throw SoundCompilationError.missingPitch }
        let base = Double(pitch.midiNote) + event.pitchOffsetSemitones
        guard base.isFinite, (0...127).contains(base) else {
            throw SoundCompilationError.pitchOutOfRange
        }
        for offset in [automation.from.value, automation.to.value] {
            let effective = base + offset
            guard effective.isFinite, (0...127).contains(effective) else {
                throw SoundCompilationError.pitchOutOfRange
            }
        }
    }

    private func validate(
        _ automation: PitchAutomation,
        events: [CompiledSoundEvent],
        sourceRange: Range<Int>
    ) throws {
        for event in events where sourceRange.contains(event.sourceID) {
            guard let pitch = event.pitch else { throw SoundCompilationError.missingPitch }
            let base = Double(pitch.midiNote) + event.pitchOffsetSemitones
            for offset in [automation.from.value, automation.to.value] {
                let value = base + offset
                guard value.isFinite, (0...127).contains(value) else {
                    throw SoundCompilationError.pitchOutOfRange
                }
            }
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

    static func eventDuckRuleCount(_ events: [CompiledSoundEvent]) -> Int {
        events.reduce(into: 0) { result, event in
            result = min(1_025, result + event.pendingEventDucks.count)
        }
    }

    static func validateEventDuckRuleBudget(
        _ events: [CompiledSoundEvent], copies: Int = 1, additionalPerEvent: Int = 0
    ) throws {
        let existing = Self.eventDuckRuleCount(events)
        let (copied, copiedOverflow) = existing.multipliedReportingOverflow(by: copies)
        let (added, addedOverflow) = events.count.multipliedReportingOverflow(by: additionalPerEvent)
        let (combined, combinedOverflow) = copied.addingReportingOverflow(added)
        guard !copiedOverflow, !addedOverflow, !combinedOverflow,
              combined <= 1_024 else {
            throw SoundCompilationError.invalidParameter("Maximum event duck rule count exceeded")
        }
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

    private func validateBusName(_ name: String) throws {
        guard name.contains(where: { !$0.isWhitespace }) else {
            throw SoundCompilationError.invalidBusRouting(.invalidName(name))
        }
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

    private func validate(_ track: Track) throws {
        guard track.level.isFinite, track.level >= 0 else {
            throw invalid("Track level must be finite and nonnegative")
        }
        if let pan = track.pan {
            guard pan.isFinite, (-1...1).contains(pan) else {
                throw invalid("Track pan must be finite and in -1...1")
            }
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
        case .sidechainCompressor(let compressor):
            guard compressor.thresholdDecibels.isFinite else {
                throw invalid("Compressor threshold must be finite")
            }
            guard compressor.ratio.isFinite, compressor.ratio >= 1 else {
                throw invalid("Compressor ratio must be at least one")
            }
            guard compressor.attackSeconds.isFinite, compressor.attackSeconds >= 0,
                  compressor.releaseSeconds.isFinite, compressor.releaseSeconds >= 0 else {
                throw invalid("Compressor attack and release must be finite and nonnegative")
            }
            guard compressor.kneeDecibels.isFinite, compressor.kneeDecibels >= 0 else {
                throw invalid("Compressor knee must be finite and nonnegative")
            }
            if let bus = compressor.sidechainBus {
                try validateBusName(bus)
            }
        case .noiseGate(let gate):
            guard gate.thresholdDecibels.isFinite else {
                throw invalid("Gate threshold must be finite")
            }
            guard gate.attackSeconds.isFinite, gate.attackSeconds >= 0,
                  gate.releaseSeconds.isFinite, gate.releaseSeconds >= 0 else {
                throw invalid("Gate attack and release must be finite and nonnegative")
            }
        case .limiter(let limiter):
            guard limiter.ceilingDecibels.isFinite, limiter.ceilingDecibels <= 0 else {
                throw invalid("Limiter ceiling must be finite and at most zero")
            }
            guard limiter.releaseSeconds.isFinite, limiter.releaseSeconds >= 0 else {
                throw invalid("Limiter release must be finite and nonnegative")
            }
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

    private struct ResolvedGraph {
        let nodes: [CompiledRenderNode]
        let roots: [Int]
        let tracks: [CompiledTrack]
    }

    private func resolvedGraph(
        rootNodeIDs: [Int],
        eventDucks: [CompiledEventDuck] = []
    ) throws -> ResolvedGraph {
        var returnIDs: [String: Int] = [:]
        var sendIDs: [String: [Int]] = [:]
        var busNames = Set<String>()
        var trackSendBuses = Set<String>()

        for (id, node) in nodes.enumerated() {
            switch node {
            case .send(_, let bus, _):
                try validateBusName(bus)
                busNames.insert(bus)
                sendIDs[bus, default: []].append(id)
            case .trackSend(_, let bus, _, _, _):
                try validateBusName(bus)
                busNames.insert(bus)
                sendIDs[bus, default: []].append(id)
                trackSendBuses.insert(bus)
            case .busReturn(let bus, _):
                try validateBusName(bus)
                busNames.insert(bus)
                guard returnIDs[bus] == nil else {
                    throw SoundCompilationError.invalidBusRouting(.duplicateReturn(bus))
                }
                returnIDs[bus] = id
            default:
                break
            }
        }

        guard busNames.count <= limits.maximumBuses else {
            throw SoundCompilationError.invalidBusRouting(
            .maximumBusesExceeded(limit: limits.maximumBuses)
            )
        }

        for bus in trackSendBuses {
            guard returnIDs[bus] != nil else {
                throw SoundCompilationError.invalidBusRouting(.missingReturn(bus))
            }
        }

        for bus in returnIDs.keys {
            guard let inputs = sendIDs[bus], !inputs.isEmpty else {
                throw SoundCompilationError.invalidBusRouting(.emptyReturn(bus))
            }
        }

        guard eventDucks.count <= 1_024 else {
            throw SoundCompilationError.invalidParameter("Maximum event duck rule count exceeded")
        }
        var duckRulesByReturnID: [Int: [Int]] = [:]
        for (ruleID, rule) in eventDucks.enumerated() {
            try validateBusName(rule.targetBus)
            guard let returnID = returnIDs[rule.targetBus] else {
                throw SoundCompilationError.invalidBusRouting(.missingReturn(rule.targetBus))
            }
            guard rule.triggerEventIndex >= 0 else {
                throw SoundCompilationError.invalidParameter("Event duck trigger index is invalid")
            }
            duckRulesByReturnID[returnID, default: []].append(ruleID)
        }

        var resolvedNodes = nodes
        for (id, node) in nodes.enumerated() {
            switch node {
            case .busReturn(let bus, _):
                resolvedNodes[id] = .busReturn(bus: bus, inputs: sendIDs[bus] ?? [])
            case .sidechainEffect(let input, let sidechain, let compressor):
                if sidechain < 0 {
                    guard let bus = sidechainBuses[id], let returnID = returnIDs[bus] else {
                        let bus = sidechainBuses[id] ?? ""
                        throw SoundCompilationError.invalidBusRouting(.missingReturn(bus))
                    }
                    resolvedNodes[id] = .sidechainEffect(
                        input: input, sidechain: returnID, compressor: compressor
                    )
                }
            default:
                break
            }
        }

        var eventDuckReplacements: [Int: Int] = [:]
        let originalNodeCount = resolvedNodes.count
        for returnID in duckRulesByReturnID.keys.sorted() {
            guard resolvedNodes.count < limits.maximumRenderNodes else {
                throw SoundCompilationError.maximumRenderNodesExceeded(limit: limits.maximumRenderNodes)
            }
            let nodeID = resolvedNodes.count
            resolvedNodes.append(
                .eventDuck(input: returnID, rules: duckRulesByReturnID[returnID] ?? [])
            )
            eventDuckReplacements[returnID] = nodeID
        }
        for id in 0..<originalNodeCount {
            resolvedNodes[id] = replacingBusConsumers(
                in: resolvedNodes[id], replacements: eventDuckReplacements
            )
        }
        guard resolvedNodes.reduce(into: 0, { count, node in
            if isDynamicsNode(node) { count += 1 }
        }) <= 32 else {
            throw SoundCompilationError.invalidParameter("Maximum dynamics node count exceeded")
        }

        var dependencies = [[Int]]()
        dependencies.reserveCapacity(resolvedNodes.count)
        var edgeCount = 0
        for node in resolvedNodes {
            let inputs: [Int]
            switch node {
            case .source:
                inputs = []
            case .mix(let values):
                inputs = values
            case .effect(let input, _):
                inputs = [input]
            case .sidechainEffect(let input, let sidechain, _):
                inputs = [input, sidechain]
            case .gain(let input, _),
                 .gainAutomation(let input, _),
                 .pan(let input, _),
                 .panAutomation(let input, _),
                 .mute(let input),
                 .track(let input, _),
                 .send(let input, _, _),
                 .trackSend(let input, _, _, _, _),
                 .output(let input, _):
                inputs = [input]
            case .busReturn(_, let values):
                inputs = values
            case .eventDuck(let input, let rules):
                guard rules.allSatisfy({ eventDucks.indices.contains($0) }) else {
                    throw SoundCompilationError.invalidParameter("Event duck rule index is invalid")
                }
                inputs = [input]
            }
            let (updatedEdges, overflow) = edgeCount.addingReportingOverflow(inputs.count)
            guard !overflow else {
                throw SoundCompilationError.invalidBusRouting(
                    .maximumEdgesExceeded(limit: limits.maximumRenderNodes)
                )
            }
            edgeCount = updatedEdges
            for input in inputs {
                guard resolvedNodes.indices.contains(input) else {
                    throw SoundCompilationError.invalidParameter("Render graph dependency is invalid")
                }
            }
            dependencies.append(inputs)
        }
        guard edgeCount <= limits.maximumRenderNodes else {
            throw SoundCompilationError.invalidBusRouting(
                .maximumEdgesExceeded(limit: limits.maximumRenderNodes)
            )
        }

        var indegrees = dependencies.map(\.count)
        var dependents = Array(repeating: [Int](), count: resolvedNodes.count)
        for (nodeID, inputs) in dependencies.enumerated() {
            for input in inputs {
                dependents[input].append(nodeID)
            }
        }

        var ready = indegrees.enumerated().compactMap { index, degree in
            degree == 0 ? index : nil
        }
        var order: [Int] = []
        order.reserveCapacity(resolvedNodes.count)
        while !ready.isEmpty {
            let nodeID = ready.removeFirst()
            order.append(nodeID)
            for dependent in dependents[nodeID] {
                indegrees[dependent] -= 1
                if indegrees[dependent] == 0 {
                    let insertion = ready.firstIndex(where: { $0 > dependent }) ?? ready.endIndex
                    ready.insert(dependent, at: insertion)
                }
            }
        }
        guard order.count == resolvedNodes.count else {
            throw SoundCompilationError.invalidBusRouting(.cycle)
        }

        var remap = Array(repeating: 0, count: resolvedNodes.count)
        for (newID, oldID) in order.enumerated() {
            remap[oldID] = newID
        }
        let remappedNodes = order.map { remappedNode(resolvedNodes[$0], using: remap) }
        let remappedRoots = try rootNodeIDs.map { root in
            let effectiveRoot = eventDuckReplacements[root] ?? root
            guard remap.indices.contains(effectiveRoot) else {
                throw SoundCompilationError.invalidParameter("Render graph root is invalid")
            }
            return remap[effectiveRoot]
        }
        let remappedTracks = try tracks.map { track in
            var copy = track
            if let renderNodeID = track.renderNodeID {
                guard remap.indices.contains(renderNodeID) else {
                    throw SoundCompilationError.invalidParameter("Track render node is invalid")
                }
                copy.renderNodeID = remap[renderNodeID]
            }
            return copy
        }
        return ResolvedGraph(nodes: remappedNodes, roots: remappedRoots, tracks: remappedTracks)
    }

    private func replacingBusConsumers(
        in node: CompiledRenderNode,
        replacements: [Int: Int]
    ) -> CompiledRenderNode {
        func replace(_ id: Int) -> Int { replacements[id] ?? id }
        switch node {
        case .source:
            return node
        case .mix(let inputs):
            return .mix(inputs: inputs.map(replace))
        case .effect(let input, let effect):
            return .effect(input: replace(input), effect: effect)
        case .sidechainEffect(let input, let sidechain, let compressor):
            return .sidechainEffect(
                input: replace(input), sidechain: replace(sidechain), compressor: compressor
            )
        case .gain(let input, let value):
            return .gain(input: replace(input), value: value)
        case .gainAutomation(let input, let automation):
            return .gainAutomation(input: replace(input), automation: automation)
        case .pan(let input, let value):
            return .pan(input: replace(input), value: value)
        case .panAutomation(let input, let automation):
            return .panAutomation(input: replace(input), automation: automation)
        case .mute(let input):
            return .mute(input: replace(input))
        case .track(let input, let trackID):
            return .track(input: replace(input), trackID: trackID)
        case .send(let input, let bus, let level):
            return .send(input: replace(input), bus: bus, level: level)
        case .trackSend(let input, let bus, let level, let trackID, let placement):
            return .trackSend(
                input: replace(input), bus: bus, level: level,
                trackID: trackID, placement: placement
            )
        case .busReturn(let bus, let inputs):
            return .busReturn(bus: bus, inputs: inputs)
        case .eventDuck(let input, let rules):
            return .eventDuck(input: input, rules: rules)
        case .output(let input, let bus):
            return .output(input: replace(input), bus: bus)
        }
    }

    private func isDynamicsNode(_ node: CompiledRenderNode) -> Bool {
        switch node {
        case .sidechainEffect, .eventDuck:
            return true
        case .effect(_, let effect):
            switch effect {
            case .compressor, .sidechainCompressor, .noiseGate, .limiter:
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    private func remappedNode(
        _ node: CompiledRenderNode,
        using remap: [Int]
    ) -> CompiledRenderNode {
        func id(_ value: Int) -> Int { remap[value] }
        switch node {
        case .source(let sourceID):
            return .source(sourceID: sourceID)
        case .mix(let inputs):
            return .mix(inputs: inputs.map(id))
        case .effect(let input, let effect):
            return .effect(input: id(input), effect: effect)
        case .sidechainEffect(let input, let sidechain, let compressor):
            return .sidechainEffect(
                input: id(input), sidechain: id(sidechain), compressor: compressor
            )
        case .gain(let input, let value):
            return .gain(input: id(input), value: value)
        case .gainAutomation(let input, let automation):
            return .gainAutomation(input: id(input), automation: automation)
        case .pan(let input, let value):
            return .pan(input: id(input), value: value)
        case .panAutomation(let input, let automation):
            return .panAutomation(input: id(input), automation: automation)
        case .mute(let input):
            return .mute(input: id(input))
        case .track(let input, let trackID):
            return .track(input: id(input), trackID: trackID)
        case .send(let input, let bus, let level):
            return .send(input: id(input), bus: bus, level: level)
        case .trackSend(let input, let bus, let level, let trackID, let placement):
            return .trackSend(
                input: id(input), bus: bus, level: level, trackID: trackID, placement: placement
            )
        case .busReturn(let bus, let inputs):
            return .busReturn(bus: bus, inputs: inputs.map(id))
        case .eventDuck(let input, let rules):
            return .eventDuck(input: id(input), rules: rules)
        case .output(let input, let bus):
            return .output(input: id(input), bus: bus)
        }
    }

    func finish(_ fragment: _SoundFragment, recurringSources: Set<Int> = []) throws -> CompiledSound {
        var events = fragment.events.enumerated().sorted {
            if $0.element.start != $1.element.start { return $0.element.start < $1.element.start }
            return $0.offset < $1.offset
        }.map(\.element)
        try _HarmonyEventProcessing.connect(&events, sources: sources, extent: fragment.extent,
                                            recurringSources: recurringSources)
        for (index, event) in events.enumerated() {
            try validateRetainedPitchAutomation(event)
            if recurringSources.contains(event.sourceID) {
                let duration = Double(event.duration.numerator) / Double(event.duration.denominator) * event.gate
                let window = Double(fragment.extent.numerator) / Double(fragment.extent.denominator)
                guard duration.isFinite, duration > 0, duration <= window else {
                    throw SoundCompilationError.liveEventDurationExceeded(index: index)
                }
            }
        }
        var eventDucks: [CompiledEventDuck] = []
        for index in events.indices {
            let pending = events[index].pendingEventDucks
            guard pending.count <= 1_024 - eventDucks.count else {
                throw SoundCompilationError.invalidParameter("Maximum event duck rule count exceeded")
            }
            for rule in pending {
                eventDucks.append(CompiledEventDuck(
                    triggerEventIndex: index,
                    targetBus: rule.targetBus,
                    depthDecibels: rule.depthDecibels,
                    attackSeconds: rule.attackSeconds,
                    recoverySeconds: rule.recoverySeconds
                ))
            }
            events[index].pendingEventDucks.removeAll(keepingCapacity: false)
        }
        let graph = try resolvedGraph(rootNodeIDs: fragment.roots, eventDucks: eventDucks)
        return CompiledSound(
            events: events, tracks: graph.tracks, sources: sources, renderNodes: graph.nodes,
            rootNodeIDs: graph.roots, eventDucks: eventDucks, extent: fragment.extent
        )
    }
}
