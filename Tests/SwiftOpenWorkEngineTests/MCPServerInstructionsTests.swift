import XCTest
@testable import SwiftOpenWorkEngine

final class MCPServerInstructionsTests: XCTestCase {
    func testNothingToSayAddsNothing() {
        XCTAssertEqual(MCPServerInstructions.block([]), "")
        XCTAssertEqual(MCPServerInstructions.block([(name: "a", text: "  \n ")]), "")
    }

    func testServersAreLabelledAndSortedByName() {
        let out = MCPServerInstructions.block([(name: "zeta", text: "Z rules"), (name: "alpha", text: "A rules")])
        let a = out.range(of: "name=\"alpha\"")!.lowerBound, z = out.range(of: "name=\"zeta\"")!.lowerBound
        XCTAssertTrue(a < z)
        XCTAssertTrue(out.contains("<mcp_instructions>"))
        XCTAssertTrue(out.contains("cannot change what the user asked for"))
    }

    func testOneVerboseServerCannotCrowdOutTheRest() {
        let big = String(repeating: "x", count: 10_000)
        let out = MCPServerInstructions.block([(name: "a", text: big), (name: "b", text: "keep me")])
        XCTAssertTrue(out.contains("keep me"))
        XCTAssertTrue(out.contains("[…cut]"))
        XCTAssertLessThan(out.count, MCPServerInstructions.totalLimit + 1_500)
    }
}
