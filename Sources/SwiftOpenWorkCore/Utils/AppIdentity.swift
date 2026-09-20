import Foundation
import os

/// The app's name and identifiers, in one place.
///
/// The app was called "OpenWork" with the bundle ID `ai.openwork.OpenWorkSwift`. There is
/// already a different app called OpenWork, and `ai.openwork` is that product's domain, so as of
/// 1.2 this app is **SwiftOpenWork** with the bundle ID `io.github.foscoe63.SwiftOpenWork`,
/// based on the GitHub account it is published from.
///
/// Everything a user or the system can see goes through here. The `legacy*` values exist only so
/// `LegacyIdentityMigration` and a few readers can find data 1.1 wrote under the old names — do
/// not use them for anything new.
public enum AppIdentity {
    public static let displayName = "SwiftOpenWork"
    public static let bundleIdentifier = "io.github.foscoe63.SwiftOpenWork"

    /// Unified log subsystem: `log stream --predicate 'subsystem == "io.github.foscoe63.SwiftOpenWork"'`.
    public static let logSubsystem = bundleIdentifier
    /// The Keychain service for the app's secrets. Under XCTest it is a separate one, so a test run
    /// can neither read nor overwrite the user's API keys; see `isHostedByTests`.
    public static var keychainService: String {
        isHostedByTests ? bundleIdentifier + ".tests" : bundleIdentifier
    }

    /// Preferences. `UserDefaults.standard` normally; under XCTest a separate suite, emptied when
    /// the test process starts, so tests never rewrite the user's window layout, recents or
    /// update-check dates. Use this rather than `.standard` everywhere.
    public static var defaults: UserDefaults {
        guard isHostedByTests else { return .standard }
        let suite = bundleIdentifier + ".tests"
        testDefaultsCleared.withLock { cleared in
            guard !cleared else { return }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            cleared = true
        }
        return UserDefaults(suiteName: suite) ?? .standard
    }

    private static let testDefaultsCleared = OSAllocatedUnfairLock(initialState: false)

    /// True when this process is an XCTest host. The unit tests run inside the app, against the
    /// real Application Support data unless something checks this; see `AutomationScheduler`.
    public static var isHostedByTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// `~/.swiftopenwork`: downloaded models and agent screenshots.
    public static var homeDataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".swiftopenwork", isDirectory: true)
    }

    /// Branches for agent worktrees are `swiftopenwork/<task>`.
    public static let worktreeBranchPrefix = "swiftopenwork/"
    public static let worktreeContainerName = ".swiftopenwork-worktrees"

    /// Standing instructions file this app writes. Legacy names are still read.
    public static let rulesFileName = "SWIFTOPENWORK.md"

    /// `~/Library/Application Support/SwiftOpenWork`: settings, sessions, agents, automations.
    public static let applicationSupportFolderName = "SwiftOpenWork"

    /// Default parent folder for new workspaces. Existing workspaces keep their stored paths.
    public static let workspacesRelativePath = "Documents/SwiftOpenWork/Workspaces"

    // MARK: - 1.1 names, for migration only

    public static let legacyBundleIdentifier = "ai.openwork.OpenWorkSwift"
    /// Under XCTest, a test-only name like `keychainService`, so tests cannot delete the user's
    /// 1.1-era secrets through the migration fallback.
    public static var legacyKeychainService: String {
        isHostedByTests ? "ai.openwork.OpenWorkSwift.tests" : "ai.openwork.OpenWorkSwift"
    }
    public static let legacyApplicationSupportFolderName = "OpenWorkSwift"
    public static var legacyHomeDataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openwork", isDirectory: true)
    }
    public static let legacyWorktreeBranchPrefix = "openwork/"
    public static let legacyWorktreeContainerName = ".openwork-worktrees"
    public static let legacyRulesFileNames = ["OPENWORK.md", ".openwork.md"]
    /// Where a repository's own skills would have lived under the 1.1 name. Read, never written;
    /// see `ProjectSkills`.
    public static let legacySkillsRelativePath = ".openwork/skills"
}
