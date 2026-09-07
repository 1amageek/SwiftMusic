/// A positive, exact rational speed for a numeric pattern phase.
public struct PatternRate: Sendable, Equatable, ExpressibleByFloatLiteral {
    public typealias FloatLiteralType = Double

    private let storage: Result<MusicalTime, PatternRateError>

    /// Creates a reduced positive rational rate.
    public init(numerator: UInt64, denominator: UInt64) throws {
        guard numerator != 0 else { throw PatternRateError.nonPositiveValue }
        guard denominator != 0 else { throw PatternRateError.zeroDenominator }
        do {
            storage = .success(try MusicalTime(numerator: numerator, denominator: denominator))
        } catch {
            storage = .failure(.overflow)
            throw PatternRateError.overflow
        }
    }

    /// Creates and eagerly validates a rate from a Double's shortest decimal spelling.
    public init(validating value: Double) throws {
        storage = .success(try Self.parse(value))
    }

    /// Retains a source float literal and defers a validation failure until pattern resolution.
    public init(floatLiteral value: Double) {
        storage = Self.validation(for: value)
    }

    internal var resolvedOrError: Result<MusicalTime, PatternRateError> {
        storage
    }

    private static func validation(for value: Double) -> Result<MusicalTime, PatternRateError> {
        do {
            return .success(try parse(value))
        } catch let error as PatternRateError {
            return .failure(error)
        } catch {
            return .failure(.overflow)
        }
    }

    private static func parse(_ value: Double) throws -> MusicalTime {
        guard value.isFinite else { throw PatternRateError.nonFiniteValue }
        guard value > 0 else { throw PatternRateError.nonPositiveValue }

        let bytes = Array(value.description.utf8)
        let exponentMarker = bytes.firstIndex { $0 == 101 || $0 == 69 }
        let mantissaEnd = exponentMarker ?? bytes.endIndex

        var exponent = 0
        if let exponentMarker {
            let start = bytes.index(after: exponentMarker)
            guard start < bytes.endIndex else { throw PatternRateError.overflow }
            exponent = try parseExponent(bytes[start...])
        }

        var cursor = bytes.startIndex
        if cursor < mantissaEnd, bytes[cursor] == 43 {
            cursor += 1
        }

        var sawDecimalPoint = false
        var fractionalDigits = 0
        var digits: [UInt8] = []
        digits.reserveCapacity(mantissaEnd)
        while cursor < mantissaEnd {
            let byte = bytes[cursor]
            if byte == 46 {
                guard !sawDecimalPoint else { throw PatternRateError.overflow }
                sawDecimalPoint = true
            } else if byte >= 48, byte <= 57 {
                digits.append(byte - 48)
                if sawDecimalPoint { fractionalDigits += 1 }
            } else {
                throw PatternRateError.overflow
            }
            cursor += 1
        }

        guard !digits.isEmpty else { throw PatternRateError.overflow }
        while digits.first == 0 { digits.removeFirst() }
        guard !digits.isEmpty else { throw PatternRateError.nonPositiveValue }

        var trailingZeros = 0
        while digits.count > 1, digits.last == 0 {
            digits.removeLast()
            trailingZeros += 1
        }

        var integer: UInt64 = 0
        for digit in digits {
            let (multiplied, multiplicationOverflow) = integer.multipliedReportingOverflow(by: 10)
            let (next, additionOverflow) = multiplied.addingReportingOverflow(UInt64(digit))
            guard !multiplicationOverflow, !additionOverflow else {
                throw PatternRateError.overflow
            }
            integer = next
        }

        let (withoutFraction, fractionOverflow) = exponent.subtractingReportingOverflow(fractionalDigits)
        let (scale, scaleOverflow) = withoutFraction.addingReportingOverflow(trailingZeros)
        guard !fractionOverflow, !scaleOverflow else { throw PatternRateError.overflow }

        if scale >= 0 {
            let power = try powerOfTen(scale)
            let (numerator, overflow) = integer.multipliedReportingOverflow(by: power)
            guard !overflow, numerator != 0 else { throw PatternRateError.overflow }
            return try MusicalTime(numerator: numerator, denominator: 1)
        }

        return try decimalFraction(integer: integer, scale: -scale)
    }

    private static func parseExponent(_ bytes: ArraySlice<UInt8>) throws -> Int {
        var index = bytes.startIndex
        var negative = false
        if bytes[index] == 43 || bytes[index] == 45 {
            negative = bytes[index] == 45
            index += 1
        }
        guard index < bytes.endIndex else { throw PatternRateError.overflow }

        var magnitude = 0
        while index < bytes.endIndex {
            let byte = bytes[index]
            guard byte >= 48, byte <= 57 else { throw PatternRateError.overflow }
            let (multiplied, multiplicationOverflow) = magnitude.multipliedReportingOverflow(by: 10)
            let (next, additionOverflow) = multiplied.addingReportingOverflow(Int(byte - 48))
            guard !multiplicationOverflow, !additionOverflow else { throw PatternRateError.overflow }
            magnitude = next
            index += 1
        }
        return negative ? -magnitude : magnitude
    }

    private static func powerOfTen(_ exponent: Int) throws -> UInt64 {
        guard exponent >= 0 else { throw PatternRateError.overflow }
        var value: UInt64 = 1
        for _ in 0..<exponent {
            let (next, overflow) = value.multipliedReportingOverflow(by: 10)
            guard !overflow else { throw PatternRateError.overflow }
            value = next
        }
        return value
    }

    private static func decimalFraction(integer: UInt64, scale: Int) throws -> MusicalTime {
        var numerator = integer
        var twos = scale
        var fives = scale

        while twos > 0, numerator.isMultiple(of: 2) {
            numerator /= 2
            twos -= 1
        }
        while fives > 0, numerator.isMultiple(of: 5) {
            numerator /= 5
            fives -= 1
        }

        var denominator: UInt64 = 1
        for _ in 0..<twos {
            let (next, overflow) = denominator.multipliedReportingOverflow(by: 2)
            guard !overflow else { throw PatternRateError.overflow }
            denominator = next
        }
        for _ in 0..<fives {
            let (next, overflow) = denominator.multipliedReportingOverflow(by: 5)
            guard !overflow else { throw PatternRateError.overflow }
            denominator = next
        }
        guard numerator != 0 else { throw PatternRateError.nonPositiveValue }
        return try MusicalTime(numerator: numerator, denominator: denominator)
    }
}
