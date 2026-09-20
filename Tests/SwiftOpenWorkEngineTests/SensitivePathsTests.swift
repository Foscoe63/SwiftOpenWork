import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage
@testable import SwiftOpenWorkEngine

/// Reading credentials asks first; ordinary reading does not.
final class SensitivePathsTests: XCTestCase {

    private var home = ""
    private var workspace = ""

    override func setUpWithError() throws {
        let base = ToolExecutionEngine.canonicalPath(NSTemporaryDirectory()) + "/sensitive-\(UUID().uuidString)"
        home = base + "/home"
        workspace = home + "/Projects/app"
        for dir in [home + "/.ssh", home + "/.aws", home + "/Library/Keychains", workspace + "/src", home + "/Documents"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: (home as NSString).deletingLastPathComponent)
    }

    private func read(_ path: String) -> String? {
        SensitivePaths.reason(forReading: path, workspaceRoot: workspace, home: home)
    }
    private func search(_ path: String) -> String? {
        SensitivePaths.reason(forSearchingUnder: path, workspaceRoot: workspace, home: home)
    }
    private func shell(_ command: String) -> String? {
        SensitivePaths.reason(forShellCommand: command, workspaceRoot: workspace, home: home)
    }

    func testCredentialLocationsAsk() {
        for path in ["~/.ssh/id_ed25519", home + "/.ssh/config", "~/.aws/credentials", "~/.netrc", "~/.zsh_history",
                     "~/Library/Keychains/login.keychain-db", "~/.config/gh/hosts.yml", "~/.docker/config.json",
                     "~/Library/Application Support/Google/Chrome/Default/Login Data",
                     "~/Library/Application Support/SwiftOpenWork/sessions.json",
                     "../../../.ssh/id_rsa"] {
            XCTAssertNotNil(read(path), path)
        }
    }

    func testSecretFilesOutsideTheWorkspaceAskAndInsideDoNot() {
        XCTAssertNotNil(read("~/Documents/other/.env"))
        XCTAssertNotNil(read("/tmp/deploy.pem"))
        XCTAssertNotNil(read("~/Downloads/id_rsa"))
        XCTAssertNil(read(".env"), "the project's own .env is ordinary work")
        XCTAssertNil(read("config/server.key"))
    }

    func testOrdinaryFilesDoNotAsk() {
        for path in ["src/main.swift", workspace + "/README.md", "~/Documents/notes.txt", "/etc/hosts", "~/.zshrc", "~/.gitconfig"] {
            XCTAssertNil(read(path), path)
        }
    }

    func testSearchesThatCoverCredentialsAsk() {
        XCTAssertNotNil(search("~"))
        XCTAssertNotNil(search(home))
        XCTAssertNotNil(search("/"))
        XCTAssertNotNil(search("~/Library"))
        XCTAssertNil(search(""), "the workspace")
        XCTAssertNil(search("src"))
        XCTAssertNil(search("~/Documents"))
    }

    func testShellCommandsThatReadCredentialsAsk() {
        for command in ["cat ~/.ssh/id_ed25519", "head -5 ~/.aws/credentials", "grep token ~/.netrc",
                        "grep -r password ~", "grep -rn key ~/Library", "rg secret ~",
                        "cat ~/.s?h/*", "cat /Users/*/.aws/credentials", "ls ~ ; cat ~/.zsh_history",
                        "cat ../../../.ssh/id_rsa", "tail ~/Downloads/.env"] {
            XCTAssertNotNil(shell(command), command)
        }
    }

    func testOrdinaryShellCommandsDoNotAsk() {
        for command in ["ls ~", "ls -la", "cat .env", "cat src/*.swift", "grep -rn TODO .", "rg foo src",
                        "git log --oneline", "cat /etc/hosts", "grep x ~/Documents/notes.txt", "wc -l *.swift"] {
            XCTAssertNil(shell(command), command)
        }
    }

    @MainActor
    func testTheApprovalCheckUsesItForFilesSearchesAndTheSafeShell() {
        var settings = AppSettings.default
        settings.terminalSafetyLevel = .safeOnly
        let readSSH = #"{"path":"~/.ssh/id_ed25519"}"#
        XCTAssertNotNil(AgentRunner.approvalReason(toolName: "file_read", argumentsJson: readSSH, settings: settings, workspaceRoot: workspace))
        XCTAssertNil(AgentRunner.approvalReason(toolName: "file_read", argumentsJson: #"{"path":"src/a.swift"}"#, settings: settings, workspaceRoot: workspace))
        XCTAssertNotNil(AgentRunner.approvalReason(toolName: "grep", argumentsJson: #"{"pattern":"x","path":"/"}"#, settings: settings, workspaceRoot: workspace))
        XCTAssertNotNil(AgentRunner.approvalReason(toolName: "terminal_command", argumentsJson: #"{"command":"cat ~/.ssh/id_ed25519"}"#, settings: settings, workspaceRoot: workspace))
        XCTAssertNil(AgentRunner.approvalReason(toolName: "terminal_command", argumentsJson: #"{"command":"ls -la"}"#, settings: settings, workspaceRoot: workspace))
    }

    func testNewInstallsAuthoriseOnlyTheWorkspaceAndStoredListsAreKept() throws {
        XCTAssertEqual(AppSettings.default.authorizedFolders, [])
        let stored = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"authorizedFolders":["/Volumes/Data"]}"#.utf8))
        XCTAssertEqual(stored.authorizedFolders, ["/Volumes/Data"])
    }
}

final class DataFolderPermissionTests: XCTestCase {

    func testTheDataFolderIsMadeOwnerOnly() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("perm-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("Checkpoints/abc")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("memories.json")
        let nested = sub.appendingPathComponent("manifest.json")
        for url in [file, nested] {
            try "{}".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        StorageService.makeOwnerOnly(dir)

        func mode(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1 }
        XCTAssertEqual(mode(dir), 0o700)
        XCTAssertEqual(mode(sub), 0o700)
        XCTAssertEqual(mode(file), 0o600)
        XCTAssertEqual(mode(nested), 0o600)
    }
}
