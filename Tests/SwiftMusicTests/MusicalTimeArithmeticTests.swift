import Testing
import SwiftMusic

struct MusicalTimeArithmeticTests {
    @Test(.timeLimit(.minutes(3)))
    func testScalingIsExactAndCancelsBeforeMultiplication() throws {
        let multipliedEighth = try MusicalTime.eighth.multiplied(by: 3)
        let expectedMultipliedEighth = try MusicalTime(numerator: 3, denominator: 2)
        #expect(multipliedEighth == expectedMultipliedEighth)
        let dividedQuarter = try MusicalTime.quarter.divided(by: 3)
        let expectedDividedQuarter = try MusicalTime(numerator: 1, denominator: 3)
        #expect(dividedQuarter == expectedDividedQuarter)
        let large = try MusicalTime(numerator: .max, denominator: 2)
        let multipliedLarge = try large.multiplied(by: 2)
        let expectedMultipliedLarge = try MusicalTime(numerator: .max, denominator: 1)
        #expect(multipliedLarge == expectedMultipliedLarge)
        #expect(try large.divided(by: .max) == .eighth)
        #expect(try large.multiplied(by: 0) == .zero)
        #expect(try MusicalTime.zero.divided(by: .max) == .zero)
    }

    @Test(.timeLimit(.minutes(3)))
    func testScalingRejectsZeroDivisorAndOverflow() throws {
        for time in [MusicalTime.zero, .quarter] {
            #expect {
                try time.divided(by: 0)
            } throws: { error in
                error as? MusicalTimeError == .divisionByZero
            }
        }
        let large = try MusicalTime(numerator: .max, denominator: 1)
        #expect {
            try large.multiplied(by: 2)
        } throws: { error in
            error as? MusicalTimeError == .overflow
        }
        let small = try MusicalTime(numerator: 1, denominator: .max)
        #expect {
            try small.divided(by: 2)
        } throws: { error in
            error as? MusicalTimeError == .overflow
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testScalingRoundTripsAcrossFractionalBeatGrid() throws {
        for numerator in UInt64(0)...12 {
            for denominator in UInt64(1)...12 {
                let time = try MusicalTime(numerator: numerator, denominator: denominator)
                for factor in UInt64(1)...8 {
                    #expect(try time.multiplied(by: factor).divided(by: factor) == time)
                    #expect(try time.divided(by: factor).multiplied(by: factor) == time)
                }
            }
        }
    }
}
