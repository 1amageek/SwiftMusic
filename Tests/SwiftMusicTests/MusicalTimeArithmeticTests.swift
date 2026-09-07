import XCTest
import SwiftMusic

final class MusicalTimeArithmeticTests: XCTestCase {
    func testScalingIsExactAndCancelsBeforeMultiplication() throws {
        XCTAssertEqual(try MusicalTime.eighth.multiplied(by: 3),
                       try MusicalTime(numerator: 3, denominator: 2))
        XCTAssertEqual(try MusicalTime.quarter.divided(by: 3),
                       try MusicalTime(numerator: 1, denominator: 3))
        let large = try MusicalTime(numerator: .max, denominator: 2)
        XCTAssertEqual(try large.multiplied(by: 2),
                       try MusicalTime(numerator: .max, denominator: 1))
        XCTAssertEqual(try large.divided(by: .max), .eighth)
        XCTAssertEqual(try large.multiplied(by: 0), .zero)
        XCTAssertEqual(try MusicalTime.zero.divided(by: .max), .zero)
    }

    func testScalingRejectsZeroDivisorAndOverflow() throws {
        for time in [MusicalTime.zero, .quarter] {
            XCTAssertThrowsError(try time.divided(by: 0)) {
                XCTAssertEqual($0 as? MusicalTimeError, .divisionByZero)
            }
        }
        let large = try MusicalTime(numerator: .max, denominator: 1)
        XCTAssertThrowsError(try large.multiplied(by: 2)) {
            XCTAssertEqual($0 as? MusicalTimeError, .overflow)
        }
        let small = try MusicalTime(numerator: 1, denominator: .max)
        XCTAssertThrowsError(try small.divided(by: 2)) {
            XCTAssertEqual($0 as? MusicalTimeError, .overflow)
        }
    }

    func testScalingRoundTripsAcrossFractionalBeatGrid() throws {
        for numerator in UInt64(0)...12 {
            for denominator in UInt64(1)...12 {
                let time = try MusicalTime(numerator: numerator, denominator: denominator)
                for factor in UInt64(1)...8 {
                    XCTAssertEqual(try time.multiplied(by: factor).divided(by: factor), time)
                    XCTAssertEqual(try time.divided(by: factor).multiplied(by: factor), time)
                }
            }
        }
    }
}
