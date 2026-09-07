internal struct _PatternTimedLeaf: Sendable, Equatable {
    let token: String
    let index: Int
    let start: MusicalTime
    let duration: MusicalTime
}

internal enum _PatternParserError: Error, Equatable, Sendable {
    case emptyInput
    case emptyGroup(offset: Int)
    case invalidToken(token: String, index: Int, offset: Int)
    case unmatchedOpeningBracket(offset: Int)
    case unmatchedClosingBracket(offset: Int)
    case inputTooLong(limit: Int)
    case tooManyLeaves(limit: Int)
    case nestingTooDeep(limit: Int)
    case timingOverflow
}

private indirect enum _PatternNode: Sendable, Equatable {
    case leaf(token: String, index: Int, offset: Int)
    case group([_PatternNode], offset: Int)
}

internal struct _MiniPatternParser: Sendable {
    static let maximumInputBytes = 64 * 1024
    static let maximumLeaves = 1_024
    static let maximumDepth = 32

    private let bytes: [UInt8]
    private var cursor = 0
    private var leafCount = 0

    init(_ source: String) throws {
        guard source.utf8.count <= Self.maximumInputBytes else {
            throw _PatternParserError.inputTooLong(limit: Self.maximumInputBytes)
        }
        bytes = Array(source.utf8)
    }

    mutating func parse() throws -> [_PatternTimedLeaf] {
        skipWhitespace()
        guard cursor < bytes.count else { throw _PatternParserError.emptyInput }
        let nodes = try parseSequence(expectClosing: false, openingOffset: nil, depth: 0)
        var leaves: [_PatternTimedLeaf] = []
        leaves.reserveCapacity(leafCount)
        let unit = MusicalTime.quarter
        do {
            try emit(nodes, start: .zero, duration: unit, into: &leaves)
        } catch is MusicalTimeError {
            throw _PatternParserError.timingOverflow
        }
        return leaves
    }

    private mutating func parseSequence(
        expectClosing: Bool,
        openingOffset: Int?,
        depth: Int
    ) throws -> [_PatternNode] {
        var nodes: [_PatternNode] = []
        while true {
            skipWhitespace()
            guard cursor < bytes.count else {
                if expectClosing {
                    throw _PatternParserError.unmatchedOpeningBracket(offset: openingOffset ?? bytes.count)
                }
                guard !nodes.isEmpty else { throw _PatternParserError.emptyInput }
                return nodes
            }

            switch bytes[cursor] {
            case 93: // ]
                guard expectClosing else {
                    throw _PatternParserError.unmatchedClosingBracket(offset: cursor)
                }
                cursor += 1
                guard !nodes.isEmpty else {
                    throw _PatternParserError.emptyGroup(offset: openingOffset ?? cursor - 1)
                }
                return nodes
            case 91: // [
                let offset = cursor
                guard depth < Self.maximumDepth else {
                    throw _PatternParserError.nestingTooDeep(limit: Self.maximumDepth)
                }
                cursor += 1
                let children = try parseSequence(
                    expectClosing: true,
                    openingOffset: offset,
                    depth: depth + 1
                )
                nodes.append(.group(children, offset: offset))
            default:
                let offset = cursor
                while cursor < bytes.count,
                      !Self.isWhitespace(bytes[cursor]),
                      bytes[cursor] != 91,
                      bytes[cursor] != 93 {
                    cursor += 1
                }
                guard cursor > offset else {
                    throw _PatternParserError.invalidToken(token: "", index: leafCount, offset: offset)
                }
                guard leafCount < Self.maximumLeaves else {
                    throw _PatternParserError.tooManyLeaves(limit: Self.maximumLeaves)
                }
                let token = String(decoding: bytes[offset..<cursor], as: UTF8.self)
                nodes.append(.leaf(token: token, index: leafCount, offset: offset))
                leafCount += 1
            }
        }
    }

    private func emit(
        _ nodes: [_PatternNode],
        start: MusicalTime,
        duration: MusicalTime,
        into leaves: inout [_PatternTimedLeaf]
    ) throws {
        guard !nodes.isEmpty else { throw _PatternParserError.emptyInput }
        let childDuration = try duration.divided(by: UInt64(nodes.count))
        for (position, node) in nodes.enumerated() {
            let childStart = try start.adding(childDuration.multiplied(by: UInt64(position)))
            switch node {
            case .leaf(let token, let index, _):
                leaves.append(_PatternTimedLeaf(
                    token: token,
                    index: index,
                    start: childStart,
                    duration: childDuration
                ))
            case .group(let children, _):
                try emit(children, start: childStart, duration: childDuration, into: &leaves)
            }
        }
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
