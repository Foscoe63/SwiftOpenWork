import XCTest
@testable import SwiftOpenWorkEngine
import SwiftOpenWorkCore

final class ShellSandboxTests: XCTestCase {
    func testProfileDeniesWritesThenAllowsWorkspace() {
        let profile = ShellSandbox.profile(writableRoots: ["/Users/me/proj"], allowNetwork: true, home: "/Users/me")
        let deny = profile.range(of: "(deny file-write*)")
        let allow = profile.range(of: "(allow file-write* (subpath \"/Users/me/proj\"))")
        XCTAssertNotNil(deny)
        XCTAssertNotNil(allow)
        // Later rules win, so the allowance must come after the blanket deny.
        XCTAssertTrue(deny!.lowerBound < allow!.lowerBound)
        XCTAssertFalse(profile.contains("deny network"))
    }

    func testNoNetworkModeBlocksRemoteButKeepsLoopback() {
        let profile = ShellSandbox.profile(writableRoots: [], allowNetwork: false, home: "/Users/me")
        XCTAssertTrue(profile.contains("(deny network-outbound (remote ip))"))
        XCTAssertTrue(profile.contains("(allow network-outbound (remote ip \"localhost:*\"))"))
    }

    func testTempRootsAreWrittenAsTheirResolvedPrivatePaths() {
        XCTAssertEqual(ShellSandbox.seatbeltPath("/var/folders/x"), "/private/var/folders/x")
        XCTAssertEqual(ShellSandbox.seatbeltPath("/tmp"), "/private/tmp")
        XCTAssertEqual(ShellSandbox.seatbeltPath("/Users/me"), "/Users/me")
    }

    func testPathsAreEscaped() {
        let profile = ShellSandbox.profile(writableRoots: ["/a\"b\\c"], allowNetwork: true, home: "/h")
        XCTAssertTrue(profile.contains("(subpath \"/a\\\"b\\\\c\")"))
    }

    func testOffModeDoesNotWrap() {
        XCTAssertNil(ShellSandbox.wrap(shellPath: "/bin/zsh", command: "ls", mode: .off, writableRoots: []))
        let wrapped = ShellSandbox.wrap(shellPath: "/bin/zsh", command: "ls", mode: .workspaceWrites, writableRoots: ["/w"])
        XCTAssertEqual(wrapped?.executable, ShellSandbox.executablePath)
        XCTAssertEqual(wrapped?.arguments.suffix(3), ["/bin/zsh", "-c", "ls"])
    }

    func testOldSettingsDecodeToOff() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.shellSandboxMode, .off)
    }
}
