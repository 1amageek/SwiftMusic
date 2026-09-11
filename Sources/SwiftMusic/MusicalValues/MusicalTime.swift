/// A normalized, non-negative rational count of quarter-note beats.
public struct MusicalTime: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let numerator: UInt64
    public let denominator: UInt64

    public static let zero = MusicalTime(uncheckedNumerator: 0, denominator: 1)
    public static let whole = MusicalTime(uncheckedNumerator: 4, denominator: 1)
    public static let half = MusicalTime(uncheckedNumerator: 2, denominator: 1)
    public static let quarter = MusicalTime(uncheckedNumerator: 1, denominator: 1)
    public static let eighth = MusicalTime(uncheckedNumerator: 1, denominator: 2)
    public static let sixteenth = MusicalTime(uncheckedNumerator: 1, denominator: 4)

    public static func beats(_ count: UInt64) -> Self {
        Self(uncheckedNumerator: count, denominator: 1)
    }

    /// Resolves bars immediately using the caller's explicit quarter-note beat count.
    public static func bars(_ count: UInt64, beatsPerBar: Int) throws -> Self {
        guard beatsPerBar > 0 else { throw MusicalTimeError.invalidBeatsPerBar(beatsPerBar) }
        return .beats(try checkedMultiply(count, UInt64(beatsPerBar)))
    }

    public init(numerator: UInt64, denominator: UInt64) throws {
        guard denominator != 0 else {
            throw MusicalTimeError.zeroDenominator
        }

        let divisor = Self.greatestCommonDivisor(numerator, denominator)
        self.numerator = numerator / divisor
        self.denominator = denominator / divisor
    }

    public var description: String {
        "\(numerator)/\(denominator)"
    }

    /// Scales musical time exactly, cancelling factors before checked arithmetic.
    public func multiplied(by factor: UInt64) throws -> MusicalTime {
        guard factor != 0, numerator != 0 else { return .zero }
        let divisor = Self.greatestCommonDivisor(factor, denominator)
        return try MusicalTime(
            numerator: Self.checkedMultiply(numerator, factor / divisor),
            denominator: denominator / divisor
        )
    }

    /// Divides musical time exactly; a zero divisor is always invalid.
    public func divided(by divisor: UInt64) throws -> MusicalTime {
        guard divisor != 0 else { throw MusicalTimeError.divisionByZero }
        guard numerator != 0 else { return .zero }
        let cancellation = Self.greatestCommonDivisor(numerator, divisor)
        return try MusicalTime(
            numerator: numerator / cancellation,
            denominator: Self.checkedMultiply(denominator, divisor / cancellation)
        )
    }

    public func adding(_ other: MusicalTime) throws -> MusicalTime {
        if numerator == 0 { return other }
        if other.numerator == 0 { return self }

        let denominatorDivisor = Self.greatestCommonDivisor(denominator, other.denominator)
        let leftDenominator = denominator / denominatorDivisor
        let rightDenominator = other.denominator / denominatorDivisor

        let leftProduct = numerator.multipliedFullWidth(by: rightDenominator)
        let rightProduct = other.numerator.multipliedFullWidth(by: leftDenominator)
        let (low, carry) = leftProduct.low.addingReportingOverflow(rightProduct.low)
        let (partialHigh, highOverflow) = leftProduct.high.addingReportingOverflow(rightProduct.high)
        let (high, carryOverflow) = partialHigh.addingReportingOverflow(carry ? 1 : 0)
        // A shared denominator factor >= 2 bounds the sum to 128 bits.
        // Otherwise no reduction is possible, so overflow cannot fit UInt64 storage.
        guard !highOverflow, !carryOverflow else { throw MusicalTimeError.overflow }

        // Reduce the high word first so full-width division has a fitting quotient.
        let remainder = denominatorDivisor.dividingFullWidth(
            (high: high % denominatorDivisor, low: low)
        ).remainder
        let numeratorDivisor = Self.greatestCommonDivisor(remainder, denominatorDivisor)
        guard high < numeratorDivisor else { throw MusicalTimeError.overflow }
        let reducedSum = numeratorDivisor.dividingFullWidth((high: high, low: low)).quotient
        let resultDenominator = try Self.checkedMultiply(
            leftDenominator,
            other.denominator / numeratorDivisor
        )
        return try MusicalTime(
            numerator: reducedSum,
            denominator: resultDenominator
        )
    }

    public static func < (lhs: MusicalTime, rhs: MusicalTime) -> Bool {
        guard lhs.denominator != rhs.denominator else {
            return lhs.numerator < rhs.numerator
        }

        let product = lhs.numerator.multipliedFullWidth(by: rhs.denominator)
        let otherProduct = rhs.numerator.multipliedFullWidth(by: lhs.denominator)
        if product.high != otherProduct.high {
            return product.high < otherProduct.high
        }
        return product.low < otherProduct.low
    }

    internal init(uncheckedNumerator numerator: UInt64, denominator: UInt64) {
        self.numerator = numerator
        self.denominator = denominator
    }

    internal static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var a = lhs
        var b = rhs
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return a == 0 ? 1 : a
    }

    internal static func checkedMultiply(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw MusicalTimeError.overflow }
        return value
    }

    internal static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw MusicalTimeError.overflow }
        return value
    }
}
