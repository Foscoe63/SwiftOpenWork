import XCTest
@testable import SwiftOpenWorkEngine

/// The calculator tool used NSExpression, which crashed the app on malformed input.
final class MathEvaluatorTests: XCTestCase {
    private func eval(_ text: String) throws -> Double { try MathEvaluator.evaluate(text) }

    func testArithmeticAndPrecedence() throws {
        XCTAssertEqual(try eval("2 + 3 * 4"), 14)
        XCTAssertEqual(try eval("(2 + 3) * 4"), 20)
        XCTAssertEqual(try eval("2 ^ 3 ^ 2"), 512, "power is right-associative")
        XCTAssertEqual(try eval("2 ** 10"), 1024)
        XCTAssertEqual(try eval("-2 ^ 2"), -4)
        XCTAssertEqual(try eval("10 % 4"), 2)
        XCTAssertEqual(try eval("7 ÷ 2"), 3.5)
        XCTAssertEqual(try eval("3 × 4"), 12)
        XCTAssertEqual(try eval("3 x 4"), 12)
        XCTAssertEqual(try eval("3x4"), 12)
        XCTAssertEqual(try eval("1.5e3 + 0x10"), 1516)
    }

    func testFunctionsAndConstants() throws {
        XCTAssertEqual(try eval("sqrt(16)"), 4)
        XCTAssertEqual(try eval("max(1, 7, 3)"), 7)
        XCTAssertEqual(try eval("pow(2, 8)"), 256)
        XCTAssertEqual(try eval("log(1000)"), 3, accuracy: 1e-12)
        XCTAssertEqual(try eval("cos(pi)"), -1, accuracy: 1e-12)
        XCTAssertEqual(try eval("ln(e)"), 1, accuracy: 1e-12)
    }

    func testMalformedInputThrowsInsteadOfCrashing() {
        for bad in ["2 +", "sqrt(4", "", ")", "2 3", "FUNCTION(1, 'foo')", "1/0", "exit()", "a = 1"] {
            XCTAssertThrowsError(try eval(bad), "'\(bad)' should be rejected")
        }
    }

    func testFormatting() {
        XCTAssertEqual(MathEvaluator.format(14), "14")
        XCTAssertEqual(MathEvaluator.format(3.5), "3.5")
        XCTAssertEqual(MathEvaluator.format(-0.25), "-0.25")
    }

    func testCalculatorNoLongerUsesNSExpression() throws {
        let source = try String(contentsOf: SourceTree.url("Engine/Tools/ToolExecutionEngine.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("NSExpression("))
    }
}
