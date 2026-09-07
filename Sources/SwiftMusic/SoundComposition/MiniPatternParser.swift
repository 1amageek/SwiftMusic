internal struct _PatternTimedLeaf: Sendable, Equatable {
    let token: String
    let index: Int
    let offset: Int
    let start: MusicalTime
    let duration: MusicalTime
}

/// A bounded program whose leaves are normalized over its complete natural period.
internal struct _PatternTimedProgram: Sendable, Equatable {
    let naturalPeriod: Int
    let leaves: [_PatternTimedLeaf]
}

internal enum _PatternParserError: Error, Equatable, Sendable {
    case emptyInput
    case emptyGroup(offset: Int)
    case invalidToken(token: String, index: Int, offset: Int)
    case invalidRepetition(token: String, index: Int, offset: Int)
    case unmatchedOpeningBracket(offset: Int)
    case unmatchedClosingBracket(offset: Int)
    case unmatchedOpeningAngleBracket(offset: Int)
    case unmatchedClosingAngleBracket(offset: Int)
    case inputTooLong(limit: Int, offset: Int)
    case tooManyLeaves(limit: Int, offset: Int)
    case nestingTooDeep(limit: Int, offset: Int)
    case timingOverflow(offset: Int)
}

private indirect enum _PatternNode: Sendable, Equatable {
    case leaf(token: String, index: Int, offset: Int, repeatCount: Int)
    case sequence([_PatternNode], offset: Int)
    case alternation([_PatternNode], offset: Int)

    var offset: Int {
        switch self {
        case .leaf(_, _, let offset, _), .sequence(_, let offset), .alternation(_, let offset):
            offset
        }
    }
}

private struct _PatternNodeMetrics: Sendable, Equatable {
    let period: Int
    let leafCount: Int
}

internal struct _MiniPatternParser: Sendable {
    static let maximumInputBytes = 64 * 1024
    static let maximumLeaves = 1_024
    static let maximumDepth = 32

    private let bytes: [UInt8]
    private var cursor = 0
    private var lexicalLeafCount = 0

    init(_ source: String) throws {
        let byteCount = source.utf8.count
        guard byteCount <= Self.maximumInputBytes else {
            throw _PatternParserError.inputTooLong(limit: Self.maximumInputBytes, offset: Self.maximumInputBytes)
        }
        bytes = Array(source.utf8)
    }

    mutating func parse() throws -> _PatternTimedProgram {
        skipWhitespace()
        guard cursor < bytes.count else { throw _PatternParserError.emptyInput }
        let root = try parseSequence(until: nil, openingOffset: nil, depth: 0, rootOffset: 0)
        let metrics = try measure(root)
        guard metrics.period > 0, metrics.leafCount > 0 else {
            throw _PatternParserError.emptyInput
        }

        var leaves: [_PatternTimedLeaf] = []
        leaves.reserveCapacity(metrics.leafCount)
        let period = UInt64(metrics.period)
        for cycle in 0..<metrics.period {
            var local: [_PatternTimedLeaf] = []
            local.reserveCapacity(metrics.leafCount / metrics.period + 1)
            do {
                try emit(root, cycle: cycle, start: .zero, duration: .quarter, into: &local)
            } catch let error as _PatternParserError {
                throw error
            }
            let cycleStart: MusicalTime
            do {
                cycleStart = try MusicalTime(numerator: UInt64(cycle), denominator: period)
                for leaf in local {
                    let normalizedStart = try cycleStart.adding(leaf.start.divided(by: period))
                    let normalizedDuration = try leaf.duration.divided(by: period)
                    leaves.append(_PatternTimedLeaf(
                        token: leaf.token,
                        index: leaf.index,
                        offset: leaf.offset,
                        start: normalizedStart,
                        duration: normalizedDuration
                    ))
                }
            } catch is MusicalTimeError {
                throw _PatternParserError.timingOverflow(offset: root.offset)
            }
        }
        guard leaves.count == metrics.leafCount else {
            throw _PatternParserError.timingOverflow(offset: root.offset)
        }
        return _PatternTimedProgram(naturalPeriod: metrics.period, leaves: leaves)
    }

    private mutating func parseSequence(
        until closing: UInt8?,
        openingOffset: Int?,
        depth: Int,
        rootOffset: Int
    ) throws -> _PatternNode {
        var nodes: [_PatternNode] = []
        while true {
            skipWhitespace()
            guard cursor < bytes.count else {
                if let closing {
                    if closing == 62 {
                        throw _PatternParserError.unmatchedOpeningAngleBracket(offset: openingOffset ?? bytes.count)
                    }
                    throw _PatternParserError.unmatchedOpeningBracket(offset: openingOffset ?? bytes.count)
                }
                guard !nodes.isEmpty else { throw _PatternParserError.emptyInput }
                return .sequence(nodes, offset: rootOffset)
            }

            let byte = bytes[cursor]
            if let closing, byte == closing {
                cursor += 1
                guard !nodes.isEmpty else {
                    throw _PatternParserError.emptyGroup(offset: openingOffset ?? cursor - 1)
                }
                return .sequence(nodes, offset: openingOffset ?? rootOffset)
            }
            switch byte {
            case 93:
                throw _PatternParserError.unmatchedClosingBracket(offset: cursor)
            case 62:
                throw _PatternParserError.unmatchedClosingAngleBracket(offset: cursor)
            default:
                nodes.append(try parseAtom(depth: depth, rootOffset: rootOffset))
            }
        }
    }

    private mutating func parseAtom(depth: Int, rootOffset: Int) throws -> _PatternNode {
        guard cursor < bytes.count else { throw _PatternParserError.emptyInput }
        let offset = cursor
        guard depth < Self.maximumDepth || (bytes[cursor] != 91 && bytes[cursor] != 60) else {
            throw _PatternParserError.nestingTooDeep(limit: Self.maximumDepth, offset: offset)
        }
        switch bytes[cursor] {
        case 91:
            cursor += 1
            return try parseSequence(until: 93, openingOffset: offset, depth: depth + 1, rootOffset: offset)
        case 60:
            cursor += 1
            return try parseAlternation(openingOffset: offset, depth: depth + 1, rootOffset: offset)
        default:
            return try parseLeaf(rootOffset: rootOffset)
        }
    }

    private mutating func parseAlternation(openingOffset: Int, depth: Int, rootOffset: Int) throws -> _PatternNode {
        var alternatives: [_PatternNode] = []
        while true {
            skipWhitespace()
            guard cursor < bytes.count else {
                throw _PatternParserError.unmatchedOpeningAngleBracket(offset: openingOffset)
            }
            if bytes[cursor] == 62 {
                cursor += 1
                guard !alternatives.isEmpty else {
                    throw _PatternParserError.emptyGroup(offset: openingOffset)
                }
                return .alternation(alternatives, offset: openingOffset)
            }
            if bytes[cursor] == 93 {
                throw _PatternParserError.unmatchedClosingBracket(offset: cursor)
            }
            alternatives.append(try parseAtom(depth: depth, rootOffset: rootOffset))
        }
    }

    private mutating func parseLeaf(rootOffset: Int) throws -> _PatternNode {
        let offset = cursor
        while cursor < bytes.count,
              !Self.isWhitespace(bytes[cursor]),
              ![91, 93, 60, 62].contains(bytes[cursor]) {
            cursor += 1
        }
        guard cursor > offset else {
            throw _PatternParserError.invalidToken(token: "", index: lexicalLeafCount, offset: offset)
        }
        guard lexicalLeafCount < Self.maximumLeaves else {
            throw _PatternParserError.tooManyLeaves(limit: Self.maximumLeaves, offset: offset)
        }
        let raw = String(decoding: bytes[offset..<cursor], as: UTF8.self)
        let (token, repeatCount) = try splitRepetition(raw, index: lexicalLeafCount, offset: offset)
        let node = _PatternNode.leaf(token: token, index: lexicalLeafCount, offset: offset, repeatCount: repeatCount)
        lexicalLeafCount += 1
        return node
    }

    private func splitRepetition(_ raw: String, index: Int, offset: Int) throws -> (String, Int) {
        let rawBytes = Array(raw.utf8)
        let stars = rawBytes.enumerated().filter { $0.element == 42 }
        guard let star = stars.first else { return (raw, 1) }
        guard stars.count == 1 else {
            let offending = stars.dropFirst().first?.offset ?? star.offset
            throw _PatternParserError.invalidRepetition(token: raw, index: index, offset: offset + offending)
        }
        guard star.offset > 0 else {
            throw _PatternParserError.invalidRepetition(token: raw, index: index, offset: offset + star.offset)
        }
        guard star.offset + 1 < rawBytes.count else {
            throw _PatternParserError.invalidRepetition(token: raw, index: index, offset: offset + star.offset)
        }
        let base = String(decoding: rawBytes[..<star.offset], as: UTF8.self)
        let countBytes = rawBytes[(star.offset + 1)...]
        var count: UInt64 = 0
        for (position, byte) in countBytes.enumerated() {
            guard (48...57).contains(byte) else {
                throw _PatternParserError.invalidRepetition(token: raw, index: index, offset: offset + star.offset + 1 + position)
            }
            let digit = UInt64(byte - 48)
            let (shifted, shiftOverflow) = count.multipliedReportingOverflow(by: 10)
            let (next, addOverflow) = shifted.addingReportingOverflow(digit)
            guard !shiftOverflow, !addOverflow else {
                throw _PatternParserError.invalidRepetition(
                    token: raw,
                    index: index,
                    offset: offset + star.offset + 1 + position
                )
            }
            count = next
        }
        guard count > 0 else {
            throw _PatternParserError.invalidRepetition(token: raw, index: index, offset: offset + star.offset)
        }
        guard count <= UInt64(Self.maximumLeaves) else {
            throw _PatternParserError.tooManyLeaves(limit: Self.maximumLeaves, offset: offset + star.offset)
        }
        return (base, Int(count))
    }

    private func measure(_ node: _PatternNode) throws -> _PatternNodeMetrics {
        switch node {
        case .leaf(_, _, _, let repeatCount):
            return _PatternNodeMetrics(period: 1, leafCount: repeatCount)
        case .sequence(let children, let offset):
            guard !children.isEmpty else { throw _PatternParserError.emptyGroup(offset: offset) }
            var period = 1
            var metrics: [_PatternNodeMetrics] = []
            metrics.reserveCapacity(children.count)
            for child in children {
                let childMetrics = try measure(child)
                metrics.append(childMetrics)
                period = try boundedLCM(period, childMetrics.period, offset: offset)
            }
            var leaves = 0
            for child in metrics {
                let occurrences = period / child.period
                leaves = try boundedAdd(leaves, try boundedMultiply(child.leafCount, occurrences, offset: offset), offset: offset)
            }
            return _PatternNodeMetrics(period: period, leafCount: leaves)
        case .alternation(let alternatives, let offset):
            guard !alternatives.isEmpty else { throw _PatternParserError.emptyGroup(offset: offset) }
            var childPeriod = 1
            var metrics: [_PatternNodeMetrics] = []
            metrics.reserveCapacity(alternatives.count)
            for child in alternatives {
                let childMetrics = try measure(child)
                metrics.append(childMetrics)
                childPeriod = try boundedLCM(childPeriod, childMetrics.period, offset: offset)
            }
            let period = try boundedMultiply(alternatives.count, childPeriod, offset: offset)
            var leaves = 0
            for child in metrics {
                let occurrences = childPeriod / child.period
                leaves = try boundedAdd(leaves, try boundedMultiply(child.leafCount, occurrences, offset: offset), offset: offset)
            }
            return _PatternNodeMetrics(period: period, leafCount: leaves)
        }
    }

    private func emit(
        _ node: _PatternNode,
        cycle: Int,
        start: MusicalTime,
        duration: MusicalTime,
        into leaves: inout [_PatternTimedLeaf]
    ) throws {
        switch node {
        case .leaf(let token, let index, let offset, let repeatCount):
            do {
                let childDuration = try duration.divided(by: UInt64(repeatCount))
                for position in 0..<repeatCount {
                    let childStart = try start.adding(childDuration.multiplied(by: UInt64(position)))
                    leaves.append(_PatternTimedLeaf(token: token, index: index, offset: offset, start: childStart, duration: childDuration))
                }
            } catch is MusicalTimeError {
                throw _PatternParserError.timingOverflow(offset: offset)
            }
        case .sequence(let children, let offset):
            do {
                let childDuration = try duration.divided(by: UInt64(children.count))
                for (position, child) in children.enumerated() {
                    let childStart = try start.adding(childDuration.multiplied(by: UInt64(position)))
                    let childPeriod = try measure(child).period
                    try emit(child, cycle: cycle % childPeriod, start: childStart, duration: childDuration, into: &leaves)
                }
            } catch let error as _PatternParserError {
                throw error
            } catch is MusicalTimeError {
                throw _PatternParserError.timingOverflow(offset: offset)
            }
        case .alternation(let alternatives, let offset):
            let selected = cycle % alternatives.count
            let localCycle = cycle / alternatives.count
            let child = alternatives[selected]
            do {
                let childPeriod = try measure(child).period
                try emit(child, cycle: localCycle % childPeriod, start: start, duration: duration, into: &leaves)
            } catch let error as _PatternParserError {
                throw error
            } catch is MusicalTimeError {
                throw _PatternParserError.timingOverflow(offset: offset)
            }
        }
    }

    private func boundedLCM(_ lhs: Int, _ rhs: Int, offset: Int) throws -> Int {
        let gcd = greatestCommonDivisor(lhs, rhs)
        return try boundedMultiply(lhs / gcd, rhs, offset: offset)
    }

    private func boundedMultiply(_ lhs: Int, _ rhs: Int, offset: Int) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw _PatternParserError.timingOverflow(offset: offset) }
        guard value <= Self.maximumLeaves else {
            throw _PatternParserError.tooManyLeaves(limit: Self.maximumLeaves, offset: offset)
        }
        return value
    }

    private func boundedAdd(_ lhs: Int, _ rhs: Int, offset: Int) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw _PatternParserError.timingOverflow(offset: offset) }
        guard value <= Self.maximumLeaves else {
            throw _PatternParserError.tooManyLeaves(limit: Self.maximumLeaves, offset: offset)
        }
        return value
    }

    private func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = lhs
        var b = rhs
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return max(a, 1)
    }

    private mutating func skipWhitespace() {
        while cursor < bytes.count, Self.isWhitespace(bytes[cursor]) { cursor += 1 }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        switch byte {
        case 9, 10, 11, 12, 13, 32: true
        default: false
        }
    }
}

internal func _scalePatternTime(_ cycle: MusicalTime, by fraction: MusicalTime) throws -> MusicalTime {
    guard cycle.numerator != 0, fraction.numerator != 0 else { return .zero }
    let firstCancellation = MusicalTime.greatestCommonDivisor(cycle.numerator, fraction.denominator)
    let secondCancellation = MusicalTime.greatestCommonDivisor(fraction.numerator, cycle.denominator)
    let numerator = try MusicalTime.checkedMultiply(
        cycle.numerator / firstCancellation,
        fraction.numerator / secondCancellation
    )
    let denominator = try MusicalTime.checkedMultiply(
        cycle.denominator / secondCancellation,
        fraction.denominator / firstCancellation
    )
    return try MusicalTime(numerator: numerator, denominator: denominator)
}

internal enum _PatternPhaseFailure: Error, Equatable, Sendable {
    case zeroFactor
    case invalidRate(PatternRateError)
    case overflow
}

/// A bounded exact cycle scale shared by deferred numeric pattern domains.
internal struct _PatternPhaseScale: Sendable, Equatable {
    let numerator: UInt64
    let denominator: UInt64
    let failure: _PatternPhaseFailure?

    static let identity = Self(numerator: 1, denominator: 1, failure: nil)

    private init(numerator: UInt64, denominator: UInt64, failure: _PatternPhaseFailure?) {
        self.numerator = numerator
        self.denominator = denominator
        self.failure = failure
    }

    func fast(_ factor: UInt64) -> Self {
        guard failure == nil else { return self }
        guard factor > 0 else {
            return Self(numerator: numerator, denominator: denominator, failure: .zeroFactor)
        }
        return composing(numerator: 1, denominator: factor)
    }

    func slow(_ factor: UInt64) -> Self {
        guard failure == nil else { return self }
        guard factor > 0 else {
            return Self(numerator: numerator, denominator: denominator, failure: .zeroFactor)
        }
        return composing(numerator: factor, denominator: 1)
    }

    func fast(_ rate: PatternRate) -> Self {
        guard failure == nil else { return self }
        switch rate.resolvedOrError {
        case .success(let rational):
            return composing(numerator: rational.denominator, denominator: rational.numerator)
        case .failure(let error):
            return Self(numerator: numerator, denominator: denominator, failure: .invalidRate(error))
        }
    }

    func slow(_ rate: PatternRate) -> Self {
        guard failure == nil else { return self }
        switch rate.resolvedOrError {
        case .success(let rational):
            return composing(numerator: rational.numerator, denominator: rational.denominator)
        case .failure(let error):
            return Self(numerator: numerator, denominator: denominator, failure: .invalidRate(error))
        }
    }

    func resolvedCycle(from cycle: MusicalTime) throws -> MusicalTime {
        if let failure { throw failure }
        do {
            let fraction = try MusicalTime(numerator: numerator, denominator: denominator)
            return try _scalePatternTime(cycle, by: fraction)
        } catch is MusicalTimeError {
            throw _PatternPhaseFailure.overflow
        }
    }

    private func normalized(numerator: UInt64, denominator: UInt64) -> Self {
        let divisor = MusicalTime.greatestCommonDivisor(numerator, denominator)
        return Self(
            numerator: numerator / divisor,
            denominator: denominator / divisor,
            failure: nil
        )
    }

    private func composing(numerator factorNumerator: UInt64, denominator factorDenominator: UInt64) -> Self {
        guard failure == nil else { return self }

        let firstCancellation = MusicalTime.greatestCommonDivisor(numerator, factorDenominator)
        let secondCancellation = MusicalTime.greatestCommonDivisor(factorNumerator, denominator)
        let leftNumerator = numerator / firstCancellation
        let rightDenominator = factorDenominator / firstCancellation
        let rightNumerator = factorNumerator / secondCancellation
        let leftDenominator = denominator / secondCancellation

        let (combinedNumerator, numeratorOverflow) = leftNumerator.multipliedReportingOverflow(by: rightNumerator)
        let (combinedDenominator, denominatorOverflow) = leftDenominator.multipliedReportingOverflow(by: rightDenominator)
        guard !numeratorOverflow, !denominatorOverflow else {
            return Self(numerator: numerator, denominator: denominator, failure: .overflow)
        }
        return normalized(numerator: combinedNumerator, denominator: combinedDenominator)
    }
}

/// A small exact unsigned integer used for rational phase comparisons.
private struct _PatternWideUInt: Equatable, Comparable {
    private var limbs: [UInt32]

    init(_ value: UInt64) {
        let low = UInt32(truncatingIfNeeded: value)
        let high = UInt32(truncatingIfNeeded: value >> 32)
        limbs = high == 0 ? [low] : [low, high]
    }

    private init(limbs: [UInt32]) {
        var normalized = limbs
        while normalized.count > 1, normalized.last == 0 {
            normalized.removeLast()
        }
        self.limbs = normalized
    }

    private var isZero: Bool { limbs.count == 1 && limbs[0] == 0 }

    static func product(_ lhs: UInt64, _ rhs: UInt64) -> Self {
        Self(lhs).multiplied(by: rhs)
    }

    func multiplied(by value: UInt64) -> Self {
        guard !isZero, value != 0 else { return Self(0) }
        let right = [
            UInt32(truncatingIfNeeded: value),
            UInt32(truncatingIfNeeded: value >> 32)
        ]
        var output = [UInt32](repeating: 0, count: limbs.count + 3)
        for leftIndex in limbs.indices {
            var carry: UInt64 = 0
            for rightIndex in right.indices {
                let index = leftIndex + rightIndex
                let product = UInt64(limbs[leftIndex]) * UInt64(right[rightIndex])
                    + UInt64(output[index]) + carry
                output[index] = UInt32(truncatingIfNeeded: product)
                carry = product >> 32
            }

            var index = leftIndex + right.count
            while carry != 0 {
                let sum = UInt64(output[index]) + carry
                output[index] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
                index += 1
            }
        }
        return Self(limbs: output)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        guard lhs.limbs.count == rhs.limbs.count else {
            return lhs.limbs.count < rhs.limbs.count
        }
        for index in lhs.limbs.indices.reversed() {
            guard lhs.limbs[index] == rhs.limbs[index] else {
                return lhs.limbs[index] < rhs.limbs[index]
            }
        }
        return false
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        precondition(lhs >= rhs)
        var output = [UInt32](repeating: 0, count: lhs.limbs.count)
        var borrow: UInt64 = 0
        for index in lhs.limbs.indices {
            let left = UInt64(lhs.limbs[index])
            let right = index < rhs.limbs.count ? UInt64(rhs.limbs[index]) : 0
            let subtrahend = right + borrow
            if left >= subtrahend {
                output[index] = UInt32(left - subtrahend)
                borrow = 0
            } else {
                output[index] = UInt32((UInt64(1) << 32) + left - subtrahend)
                borrow = 1
            }
        }
        return Self(limbs: output)
    }

    private func bit(at index: Int) -> Bool {
        guard index >= 0, index / 32 < limbs.count else { return false }
        return (limbs[index / 32] & (UInt32(1) << UInt32(index % 32))) != 0
    }

    private func shiftedLeftOne() -> Self {
        var output = [UInt32](repeating: 0, count: limbs.count + 1)
        var carry: UInt64 = 0
        for index in limbs.indices {
            let shifted = (UInt64(limbs[index]) << 1) | carry
            output[index] = UInt32(truncatingIfNeeded: shifted)
            carry = shifted >> 32
        }
        output[limbs.count] = UInt32(truncatingIfNeeded: carry)
        return Self(limbs: output)
    }

    func modulo(_ divisor: Self) -> Self {
        precondition(!divisor.isZero)
        var remainder = Self(0)
        let bitCount = limbs.count * 32
        for index in stride(from: bitCount - 1, through: 0, by: -1) {
            remainder = remainder.shiftedLeftOne()
            if bit(at: index) {
                remainder = remainder + Self(1)
            }
            if remainder >= divisor {
                remainder = remainder - divisor
            }
        }
        return remainder
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        let count = max(lhs.limbs.count, rhs.limbs.count)
        var output = [UInt32](repeating: 0, count: count + 1)
        var carry: UInt64 = 0
        for index in 0..<count {
            let left = index < lhs.limbs.count ? UInt64(lhs.limbs[index]) : 0
            let right = index < rhs.limbs.count ? UInt64(rhs.limbs[index]) : 0
            let sum = left + right + carry
            output[index] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
        }
        output[count] = UInt32(truncatingIfNeeded: carry)
        return Self(limbs: output)
    }
}

internal func _patternLeafIndex(
    at start: MusicalTime,
    cycle: MusicalTime,
    leaves: [_PatternTimedLeaf]
) -> Int? {
    guard cycle > .zero, !leaves.isEmpty else { return nil }
    let numerator = _PatternWideUInt.product(start.numerator, cycle.denominator)
    let denominator = _PatternWideUInt.product(start.denominator, cycle.numerator)
    let remainder = numerator.modulo(denominator)

    for (position, leaf) in leaves.enumerated() {
        let begins = remainder.multiplied(by: leaf.start.denominator)
        let beginBoundary = denominator.multiplied(by: leaf.start.numerator)
        guard begins >= beginBoundary else { continue }

        let end: MusicalTime
        do {
            end = try leaf.start.adding(leaf.duration)
        } catch {
            continue
        }
        let beforeEnd = remainder.multiplied(by: end.denominator)
        let endBoundary = denominator.multiplied(by: end.numerator)
        if beforeEnd < endBoundary {
            return position
        }
    }
    return nil
}
