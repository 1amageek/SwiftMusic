internal enum _PatternTransformOperation: Sendable, Equatable {
    case fast(UInt64)
    case slow(UInt64)
    case fastRate(PatternRate)
    case slowRate(PatternRate)
    case phase(MusicalTime)
    case reverse
    case repeatCycles(UInt64)
}

internal struct _PatternResolvedTransform: Sendable, Equatable {
    let program: _PatternTimedProgram
    let cycle: MusicalTime

    var period: MusicalTime {
        get throws { try cycle.multiplied(by: UInt64(program.naturalPeriod)) }
    }
}

/// Ordered, bounded transformations of a domain pattern's local cycles.
internal struct _PatternTransform: Sendable, Equatable {
    private let operations: [_PatternTransformOperation]
    private let failure: _PatternPhaseFailure?
    static let identity = Self(operations: [], failure: nil)

    func fast(_ factor: UInt64) -> Self { appending(.fast(factor)) }
    func slow(_ factor: UInt64) -> Self { appending(.slow(factor)) }
    func fast(_ rate: PatternRate) -> Self { appending(.fastRate(rate)) }
    func slow(_ rate: PatternRate) -> Self { appending(.slowRate(rate)) }
    func phase(_ offset: MusicalTime) -> Self { appending(.phase(offset)) }
    func reversed() -> Self { appending(.reverse) }
    func repeated(_ count: UInt64) -> Self { appending(.repeatCycles(count)) }

    func resolve(
        _ base: _PatternTimedProgram,
        cycle: MusicalTime,
        splitWrappedLeaves: Bool = false
    ) throws -> _PatternResolvedTransform {
        guard cycle > .zero else { throw _PatternPhaseFailure.zeroFactor }
        var program = base
        var scale = _PatternPhaseScale.identity
        for operation in operations {
            switch operation {
            case .fast(let factor): scale = scale.fast(factor)
            case .slow(let factor): scale = scale.slow(factor)
            case .fastRate(let rate): scale = scale.fast(rate)
            case .slowRate(let rate): scale = scale.slow(rate)
            case .phase(let offset):
                let localCycle = try scale.resolvedCycle(from: cycle)
                let remainder = try _patternTimeRemainder(offset, divisor: localCycle)
                let fraction = try _scalePatternTime(remainder, by: MusicalTime(
                    numerator: localCycle.denominator, denominator: localCycle.numerator))
                program = try reposition(program, advance: fraction, reverse: false, split: splitWrappedLeaves)
            case .reverse:
                program = try reposition(program, advance: .zero, reverse: true, split: splitWrappedLeaves)
            case .repeatCycles(let count):
                program = try repeated(program, count: count)
            }
            if let failure = scale.failure { throw failure }
        }
        if let failure { throw failure }
        return _PatternResolvedTransform(program: program, cycle: try scale.resolvedCycle(from: cycle))
    }

    private func appending(_ operation: _PatternTransformOperation) -> Self {
        guard failure == nil else { return self }
        guard operations.count < _MiniPatternParser.maximumLeaves else {
            return Self(operations: operations, failure: .overflow)
        }
        return Self(operations: operations + [operation], failure: nil)
    }

    private func reposition(
        _ program: _PatternTimedProgram,
        advance: MusicalTime,
        reverse: Bool,
        split: Bool
    ) throws -> _PatternTimedProgram {
        let count = UInt64(program.naturalPeriod)
        let width = try MusicalTime.quarter.divided(by: count)
        let delta = try advance.divided(by: count)
        var leaves: [_PatternTimedLeaf] = []
        leaves.reserveCapacity(program.leaves.count)
        for leaf in program.leaves {
            let position = try leaf.start.multiplied(by: count)
            let cycleStart = try MusicalTime(numerator: position.numerator / position.denominator, denominator: count)
            let localStart = try _subtractPatternTime(leaf.start, cycleStart)
            let mirroredOrShifted: MusicalTime
            if reverse {
                let end = try _patternTimeRemainder(localStart.adding(leaf.duration), divisor: width)
                mirroredOrShifted = end == .zero ? .zero : try _subtractPatternTime(width, end)
            } else {
                mirroredOrShifted = localStart >= delta
                    ? try _subtractPatternTime(localStart, delta)
                    : try _subtractPatternTime(width, _subtractPatternTime(delta, localStart))
            }
            let start = try cycleStart.adding(mirroredOrShifted)
            let remaining = try _subtractPatternTime(width, mirroredOrShifted)
            if split && leaf.duration > remaining {
                try append(leaf, start: start, duration: remaining, into: &leaves)
                try append(leaf, start: cycleStart,
                    duration: _subtractPatternTime(leaf.duration, remaining), into: &leaves)
            } else {
                try append(leaf, start: start, duration: leaf.duration, into: &leaves)
            }
        }
        leaves.sort { $0.start < $1.start }
        return _PatternTimedProgram(naturalPeriod: program.naturalPeriod, leaves: leaves)
    }

    private func repeated(_ program: _PatternTimedProgram, count: UInt64) throws -> _PatternTimedProgram {
        guard count > 0 else { throw _PatternPhaseFailure.zeroFactor }
        let divisor = MusicalTime.greatestCommonDivisor(UInt64(program.naturalPeriod), count)
        let copies = count / divisor
        let (leafCount, overflow) = UInt64(program.leaves.count).multipliedReportingOverflow(by: copies)
        guard !overflow, leafCount <= UInt64(_MiniPatternParser.maximumLeaves) else {
            throw _PatternPhaseFailure.overflow
        }
        var leaves: [_PatternTimedLeaf] = []
        leaves.reserveCapacity(Int(leafCount))
        for copy in 0..<copies {
            let base = try MusicalTime(numerator: copy, denominator: copies)
            for leaf in program.leaves {
                try append(leaf, start: base.adding(leaf.start.divided(by: copies)),
                    duration: leaf.duration.divided(by: copies), into: &leaves)
            }
        }
        return _PatternTimedProgram(naturalPeriod: program.naturalPeriod / Int(divisor), leaves: leaves)
    }

    private func append(
        _ leaf: _PatternTimedLeaf,
        start: MusicalTime,
        duration: MusicalTime,
        into leaves: inout [_PatternTimedLeaf]
    ) throws {
        guard leaves.count < _MiniPatternParser.maximumLeaves else { throw _PatternPhaseFailure.overflow }
        leaves.append(_PatternTimedLeaf(token: leaf.token, index: leaf.index, offset: leaf.offset,
            start: start, duration: duration))
    }
}

private func _patternTimeRemainder(_ value: MusicalTime, divisor: MusicalTime) throws -> MusicalTime {
    guard divisor > .zero else { throw MusicalTimeError.divisionByZero }
    if value < divisor { return value }
    let common = MusicalTime.greatestCommonDivisor(value.denominator, divisor.denominator)
    let left = try MusicalTime.checkedMultiply(value.numerator, divisor.denominator / common)
    let right = try MusicalTime.checkedMultiply(divisor.numerator, value.denominator / common)
    return try MusicalTime(numerator: left % right,
        denominator: MusicalTime.checkedMultiply(value.denominator / common, divisor.denominator))
}

private func _subtractPatternTime(_ lhs: MusicalTime, _ rhs: MusicalTime) throws -> MusicalTime {
    guard lhs >= rhs else { throw MusicalTimeError.overflow }
    guard rhs.numerator != 0 else { return lhs }

    let denominatorDivisor = MusicalTime.greatestCommonDivisor(lhs.denominator, rhs.denominator)
    let leftDenominator = lhs.denominator / denominatorDivisor
    let rightDenominator = rhs.denominator / denominatorDivisor
    let leftProduct = try MusicalTime.checkedMultiply(lhs.numerator, rightDenominator)
    let rightProduct = try MusicalTime.checkedMultiply(rhs.numerator, leftDenominator)
    let difference = leftProduct - rightProduct
    let numeratorDivisor = MusicalTime.greatestCommonDivisor(difference, denominatorDivisor)
    return try MusicalTime(
        numerator: difference / numeratorDivisor,
        denominator: try MusicalTime.checkedMultiply(leftDenominator, rhs.denominator / numeratorDivisor)
    )
}
