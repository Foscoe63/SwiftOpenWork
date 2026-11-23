import XCTest
@testable import SwiftOpenWorkEngine

final class AgentSecretsTests: XCTestCase {
    func testNamesMustBeShellVariables() {
        XCTAssertTrue(AgentSecrets.isValidName("GITHUB_TOKEN"))
        XCTAssertTrue(AgentSecrets.isValidName("API_KEY_2"))
        XCTAssertFalse(AgentSecrets.isValidName("github_token"))
        XCTAssertFalse(AgentSecrets.isValidName("1TOKEN"))
        XCTAssertFalse(AgentSecrets.isValidName("A"))
        XCTAssertFalse(AgentSecrets.isValidName("TOKEN; rm -rf /"))
    }

    func testRedactionReplacesValuesLongestFirst() {
        let secrets = [(name: "SHORT", value: "abcdef"), (name: "LONG", value: "abcdef-ghijkl")]
        let out = AgentSecrets.redact("key=abcdef-ghijkl and abcdef", secrets: secrets)
        XCTAssertEqual(out, "key=[secret LONG] and [secret SHORT]")
    }

    func testShortValuesAreNotRedacted() {
        XCTAssertEqual(AgentSecrets.redact("pin 1234 ok", secrets: [(name: "PIN", value: "1234")]), "pin 1234 ok")
    }
}
