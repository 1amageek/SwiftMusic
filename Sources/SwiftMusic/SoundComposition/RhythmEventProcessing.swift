import Foundation

/// Exact event transformations; source identity and render-graph ownership stay with the compiler.
internal enum _RhythmEventProcessing {
    static func apply(_ modifier: _SoundModifier, events: [CompiledSoundEvent],
                      extent: MusicalTime, limits: SoundCompiler.Limits,
                      livePeriod: MusicalTime?, maximumOutputEvents: Int) throws -> _SoundFragment {
        do {
            var output: [CompiledSoundEvent] = []
            var end = extent
            switch modifier {
            case .euclidean(let rhythm):
                try budget(events, copies: rhythm.pulses, maximum: maximumOutputEvents, limits: limits)
                let hits = euclidean(rhythm)
                let duration = try rhythm.cycle.divided(by: UInt64(rhythm.steps))
                output.reserveCapacity(events.count * rhythm.pulses)
                for step in hits.indices where hits[step] {
                    let offset = try duration.multiplied(by: UInt64(step))
                    for original in events {
                        var event = original
                        event.start = try original.start.adding(offset)
                        event.duration = duration
                        output.append(event)
                    }
                }
                end = rhythm.cycle
            case .ratchet(let count):
                guard (1...1_024).contains(count) else { throw RhythmTransformError.invalidRatchet }
                try budget(events, copies: count, maximum: maximumOutputEvents, limits: limits)
                output.reserveCapacity(events.count * count)
                for event in events { try ratchet(event, count: count, into: &output) }
            case .probability(let value):
                if value.chance == 1 { output = events }
                else if value.chance != 0 {
                    let threshold = UInt64(floor(value.chance * 9_007_199_254_740_992))
                    output = events.enumerated().compactMap { ordinal, event in
                        random(seed: value.seed, ordinal: ordinal, lane: 0) >> 11 < threshold ? event : nil
                    }
                }
            case .swing(let value):
                output = events
                for index in output.indices {
                    let cell = try quotient(output[index].start, value.subdivision)
                    if cell % 2 == 1 {
                        output[index].start = try output[index].start.adding(value.delay)
                        if let livePeriod {
                            output[index].start = try _patternTimeRemainder(output[index].start, divisor: livePeriod)
                        }
                    }
                }
            case .humanize(let value):
                output = events
                for index in output.indices {
                    let timing = try choice(value.timingOffsets, seed: value.seed, ordinal: index, lane: 0)
                    let velocity = try choice(value.velocityOffsets, seed: value.seed, ordinal: index, lane: 1)
                    let shift = try value.timingStep.multiplied(by: UInt64(timing.magnitude))
                    if let livePeriod {
                        let start = try _patternTimeRemainder(output[index].start, divisor: livePeriod)
                        let shift = try _patternTimeRemainder(shift, divisor: livePeriod)
                        if timing >= 0 {
                            output[index].start = try _patternTimeRemainder(start.adding(shift), divisor: livePeriod)
                        } else if start >= shift { output[index].start = try _subtractPatternTime(start, shift) }
                        else { output[index].start = try _subtractPatternTime(livePeriod, _subtractPatternTime(shift, start)) }
                    } else if timing >= 0 { output[index].start = try output[index].start.adding(shift) }
                    else {
                        guard output[index].start >= shift else { throw RhythmTransformError.negativeEventTime }
                        output[index].start = try _subtractPatternTime(output[index].start, shift)
                    }
                    let current = output[index].velocity
                    output[index].velocity = velocity > 127 - current ? 127
                        : velocity < 1 - current ? 1 : current + velocity
                }
            case .periodically(let value):
                var total = 0
                var rules = 0
                for event in events {
                    let count = try periodicCount(event, value: value)
                    let (next, overflow) = total.addingReportingOverflow(count)
                    guard !overflow, next <= maximumOutputEvents else {
                        throw SoundCompilationError.maximumEventsExceeded(limit: limits.maximumEvents)
                    }
                    total = next
                    let (additionalRules, ruleOverflow) = event.pendingEventDucks.count.multipliedReportingOverflow(by: count)
                    guard !ruleOverflow, additionalRules <= 1_024 - rules else {
                        throw SoundCompilationError.invalidParameter("Maximum event duck rule count exceeded")
                    }
                    rules += additionalRules
                }
                output.reserveCapacity(total)
                for original in events {
                    let cycle = try quotient(original.start, value.cycle)
                    guard (cycle % value.every + value.phase) % value.every == 0 else {
                        output.append(original); continue
                    }
                    let origin = try value.cycle.multiplied(by: cycle)
                    let local = try _subtractPatternTime(original.start, origin)
                    var event = original
                    switch value.transform {
                    case .reversed:
                        event.start = try origin.adding(_subtractPatternTime(value.cycle, local.adding(event.duration)))
                        output.append(event)
                    case .rotated(let offset):
                        event.start = try origin.adding(_patternTimeRemainder(local.adding(offset), divisor: value.cycle))
                        output.append(event)
                    case .ratcheted(let count): try ratchet(event, count: count, into: &output)
                    }
                }
            default: preconditionFailure("Only rhythm event modifiers enter this processor")
            }
            if let livePeriod { end = livePeriod }
            else {
                for event in output { end = max(end, try event.start.adding(event.duration)) }
            }
            return _SoundFragment(events: output, extent: end)
        } catch is MusicalTimeError { throw RhythmTransformError.timingOverflow }
    }

    private static func quotient(_ value: MusicalTime, _ divisor: MusicalTime) throws -> UInt64 {
        let ratio = try _scalePatternTime(value, by: MusicalTime(numerator: divisor.denominator,
                                                               denominator: divisor.numerator))
        return ratio.numerator / ratio.denominator
    }

    private static func budget(_ events: [CompiledSoundEvent], copies: Int, maximum: Int,
                               limits: SoundCompiler.Limits) throws {
        guard events.isEmpty || copies <= maximum / events.count else {
            throw SoundCompilationError.maximumEventsExceeded(limit: limits.maximumEvents)
        }
        try _SoundCompilationContext.validateEventDuckRuleBudget(events, copies: copies)
    }

    private static func ratchet(_ original: CompiledSoundEvent, count: Int,
                                into output: inout [CompiledSoundEvent]) throws {
        let duration = try original.duration.divided(by: UInt64(count))
        for index in 0..<count {
            var event = original
            event.start = try original.start.adding(duration.multiplied(by: UInt64(index)))
            event.duration = duration
            output.append(event)
        }
    }

    private static func periodicCount(_ event: CompiledSoundEvent,
                                      value: PeriodicRhythmTransform) throws -> Int {
        let local = try _patternTimeRemainder(event.start, divisor: value.cycle)
        guard try local.adding(event.duration) <= value.cycle else { throw RhythmTransformError.crossingCycle }
        let cycle = try quotient(event.start, value.cycle)
        if (cycle % value.every + value.phase) % value.every == 0,
           case .ratcheted(let count) = value.transform { return count }
        return 1
    }

    // SplitMix64: explicit seed/ordinal/lane identity; wrapping arithmetic is intentional.
    private static func random(seed: UInt64, ordinal: Int, lane: UInt64, attempt: UInt64 = 0) -> UInt64 {
        var value = seed &+ 0x9E3779B97F4A7C15 &* (UInt64(ordinal) &+ 1)
            &+ 0xD1B54A32D192ED03 &* lane &+ 0x94D049BB133111EB &* attempt
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    private static func choice(_ range: ClosedRange<Int>, seed: UInt64, ordinal: Int, lane: UInt64) throws -> Int {
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        let rejection = (0 &- width) % width
        for attempt in UInt64(0)..<16 {
            let value = random(seed: seed, ordinal: ordinal, lane: lane, attempt: attempt)
            if value >= rejection { return range.lowerBound + Int(value % width) }
        }
        throw RhythmTransformError.deterministicRandomness
    }

    private static func euclidean(_ rhythm: EuclideanRhythm) -> [Bool] {
        if rhythm.pulses == 0 { return Array(repeating: false, count: rhythm.steps) }
        if rhythm.pulses == rhythm.steps { return Array(repeating: true, count: rhythm.steps) }
        var counts: [Int] = []
        var remainders = [rhythm.pulses]
        var divisor = rhythm.steps - rhythm.pulses
        var level = 0
        repeat {
            counts.append(divisor / remainders[level])
            remainders.append(divisor % remainders[level])
            divisor = remainders[level]
            level += 1
        } while remainders[level] > 1
        counts.append(divisor)
        var pattern: [Bool] = []
        pattern.reserveCapacity(rhythm.steps)
        func build(_ level: Int) {
            if level == -1 { pattern.append(false) }
            else if level == -2 { pattern.append(true) }
            else {
                for _ in 0..<counts[level] { build(level - 1) }
                if remainders[level] != 0 { build(level - 2) }
            }
        }
        build(level)
        let first = pattern.firstIndex(of: true)!
        return (0..<rhythm.steps).map { step in
            pattern[(step - rhythm.rotation + rhythm.steps + first) % rhythm.steps]
        }
    }
}
