/// Captured during the finite compiler pass; owns no source or render-graph allocation.
internal struct _LiveEventProgram {
    private indirect enum Operation {
        case seeds([CompiledSoundEvent])
        case group([_LiveEventProgram])
        case generator(_LiveEventProgram, _SoundModifier)
        case modifier(_LiveEventProgram, _SoundModifier)
    }

    private let operation: Operation
    let period: MusicalTime?
    private let finiteExtent: MusicalTime?
    private let sourceIDs: Set<Int>
    private let recurringSourceIDs: Set<Int>

    static func finite(_ fragment: _SoundFragment) -> Self {
        Self(operation: .seeds(fragment.events), period: nil,
             finiteExtent: fragment.extent, sourceIDs: Set(fragment.events.map(\.sourceID)),
             recurringSourceIDs: [])
    }

    static func group(_ children: [Self]) throws -> Self {
        var period: MusicalTime?
        var finiteExtent: MusicalTime?
        var sources: Set<Int> = []
        var recurring: Set<Int> = []
        for child in children {
            period = try commonPeriod(period, child.period)
            if let extent = child.finiteExtent { finiteExtent = max(finiteExtent ?? .zero, extent) }
            sources.formUnion(child.sourceIDs)
            recurring.formUnion(child.recurringSourceIDs)
        }
        return Self(operation: .group(children), period: period, finiteExtent: finiteExtent,
                    sourceIDs: sources, recurringSourceIDs: recurring)
    }

    func applying(_ modifier: _SoundModifier, finite: _SoundFragment) throws -> Self {
        switch modifier {
        case .oneShot:
            return .finite(finite)
        case .rhythm(let pattern, let cycle, _):
            return try generator(modifier, period: pattern.resolvedTransform(cycle: cycle).period)
        case .notePattern(let pattern, let cycle, _):
            return try generator(modifier, period: pattern.resolvedTransform(cycle: cycle).period)
        case .repeated:
            guard period != nil else { return .finite(finite) }
            return Self(operation: .seeds(finite.events), period: finite.extent,
                        finiteExtent: nil, sourceIDs: sourceIDs, recurringSourceIDs: sourceIDs)
        case .tuning, .sampleRegion, .sampleReversed, .samplePlaybackRate, .unison,
             .voicePolicy, .chokeGroup,
             .effect, .gain, .pan, .muted, .send, .output,
             .pitchEnvelope, .filterEnvelope:
            return self
        default:
            guard var period else { return .finite(finite) }
            var extent = finiteExtent
            switch modifier {
            case .gainPattern(let pattern, let cycle):
                period = try Self.commonPeriod(period, pattern.resolvedTransform(cycle: cycle).period)!
            case .panPattern(let pattern, let cycle):
                period = try Self.commonPeriod(period, pattern.resolvedTransform(cycle: cycle).period)!
            case .pitchPattern(let pattern, let cycle):
                period = try Self.commonPeriod(period, pattern.resolvedTransform(cycle: cycle).period)!
            case .cutoffPattern(_, let pattern, let cycle, _, _):
                period = try Self.commonPeriod(period, pattern.resolvedTransform(cycle: cycle).period)!
            case .envelopePattern(let pattern, let cycle):
                period = try Self.commonPeriod(period, pattern.resolvedTransform(cycle: cycle).period)!
            case .sampleSelection(let pattern, let cycle):
                period = try Self.commonPeriod(period, pattern.resolvedTransform(cycle: cycle).period)!
            case .fast(let factor):
                period = try period.divided(by: factor)
                extent = try extent?.divided(by: factor)
            case .slow(let factor):
                period = try period.multiplied(by: factor)
                extent = try extent?.multiplied(by: factor)
            case .offset(let offset):
                extent = try extent?.adding(offset)
            default: break
            }
            return Self(operation: .modifier(self, modifier), period: period, finiteExtent: extent,
                        sourceIDs: sourceIDs, recurringSourceIDs: recurringSourceIDs)
        }
    }

    private func generator(_ modifier: _SoundModifier, period generatingPeriod: MusicalTime) throws -> Self {
        Self(operation: .generator(self, modifier),
             period: try Self.commonPeriod(period, generatingPeriod), finiteExtent: nil,
             sourceIDs: sourceIDs, recurringSourceIDs: sourceIDs)
    }

    func window(policy: LiveLoopPolicy) throws -> MusicalTime {
        let bar = try MusicalTime(numerator: UInt64(policy.beatsPerBar), denominator: 1)
        let common = try Self.commonPeriod(period, bar)!
        guard common <= policy.maximumBeats, (finiteExtent ?? .zero) <= policy.maximumBeats else {
            throw SoundCompilationError.liveWindowExceeded(maximum: policy.maximumBeats)
        }
        let needed = max(common, finiteExtent ?? .zero)
        let ratio = try _scalePatternTime(needed, by: MusicalTime(
            numerator: common.denominator, denominator: common.numerator))
        let count = try MusicalTime.checkedAdd(ratio.numerator / ratio.denominator,
                                               ratio.numerator % ratio.denominator == 0 ? 0 : 1)
        let result = try common.multiplied(by: count)
        guard result <= policy.maximumBeats else {
            throw SoundCompilationError.liveWindowExceeded(maximum: policy.maximumBeats)
        }
        return result
    }

    /// Materializes one complete parameter period before copying its proven periodic values.
    func emit(
        through horizon: MusicalTime,
        limits: SoundCompiler.Limits,
        sources: [CompiledSource]
    ) throws -> [CompiledSoundEvent] {
        let events = try canonical(limits: limits, sources: sources)
        guard let period, !events.isEmpty else { return events }
        let ratio = try _scalePatternTime(horizon, by: MusicalTime(
            numerator: period.denominator, denominator: period.numerator))
        guard ratio.denominator == 1 else {
            throw SoundCompilationError.invalidParameter("Live horizon must contain whole recurrence periods")
        }
        let recurringCount = events.reduce(0) { $0 + (recurringSourceIDs.contains($1.sourceID) ? 1 : 0) }
        let finiteCount = events.count - recurringCount
        guard recurringCount == 0 || ratio.numerator <= UInt64((limits.maximumEvents - finiteCount) / recurringCount) else {
            throw SoundCompilationError.maximumEventsExceeded(limit: limits.maximumEvents)
        }
        guard recurringCount > 0 else { return events }
        var output: [CompiledSoundEvent] = []
        output.reserveCapacity(finiteCount + recurringCount * Int(ratio.numerator))
        for iteration in 0..<ratio.numerator {
            let origin = try period.multiplied(by: iteration)
            for original in events {
                let recurring = recurringSourceIDs.contains(original.sourceID)
                guard recurring || iteration == 0 else { continue }
                var event = original
                if recurring {
                    event.start = try _patternTimeRemainder(original.start, divisor: period).adding(origin)
                }
                output.append(event)
            }
        }
        return output
    }

    private func canonical(
        limits: SoundCompiler.Limits,
        sources: [CompiledSource]
    ) throws -> [CompiledSoundEvent] {
        switch operation {
        case .seeds(let events): return events
        case .group(let children):
            var events: [CompiledSoundEvent] = []
            for child in children {
                let next = try child.emit(
                    through: period ?? .quarter, limits: limits, sources: sources
                )
                guard next.count <= limits.maximumEvents - events.count else {
                    throw SoundCompilationError.maximumEventsExceeded(limit: limits.maximumEvents)
                }
                events.append(contentsOf: next)
            }
            return events
        case .generator(let child, let modifier):
            let events = try child.emit(
                through: period ?? .quarter, limits: limits, sources: sources
            )
            return try _SoundCompilationContext.applyEvents(
                modifier,
                events: events,
                extent: .zero,
                limits: limits,
                sources: sources,
                sourceIDs: sourceIDs
            ).events
        case .modifier(let child, let modifier):
            let horizon: MusicalTime
            switch modifier {
            case .fast, .slow: horizon = child.period ?? .quarter
            default: horizon = period ?? .quarter
            }
            let events = try child.emit(through: horizon, limits: limits, sources: sources)
            return try _SoundCompilationContext.applyEvents(
                modifier,
                events: events,
                extent: .zero,
                limits: limits,
                sources: sources,
                sourceIDs: sourceIDs
            ).events
        }
    }

    private static func commonPeriod(_ lhs: MusicalTime?, _ rhs: MusicalTime?) throws -> MusicalTime? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        let divisor = MusicalTime.greatestCommonDivisor(lhs.numerator, rhs.numerator)
        return try MusicalTime(
            numerator: MusicalTime.checkedMultiply(lhs.numerator / divisor, rhs.numerator),
            denominator: MusicalTime.greatestCommonDivisor(lhs.denominator, rhs.denominator))
    }
}
