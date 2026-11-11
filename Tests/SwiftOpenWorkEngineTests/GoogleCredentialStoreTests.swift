import XCTest
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage

/// Opening Settings → Google must not read the Keychain on the main thread, nor rewrite what it read.
final class GoogleCredentialStoreTests: XCTestCase {

    private final class Keychain: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: String]
        private(set) var readThreads: [Bool] = []
        private var readKeys: [String] = []
        private var writeLog: [String] = []

        init(_ items: [String: String] = [:]) { self.items = items }

        func read(_ key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            readKeys.append(key)
            readThreads.append(Thread.isMainThread)
            return items[key]
        }

        func write(_ value: String, _ key: String) {
            lock.lock(); defer { lock.unlock() }
            writeLog.append("\(key)=\(value)")
            items[key] = value
        }

        var reads: [String] { lock.lock(); defer { lock.unlock() }; return readKeys }
        var writes: [String] { lock.lock(); defer { lock.unlock() }; return writeLog }
        var readOnMain: Bool { lock.lock(); defer { lock.unlock() }; return readThreads.contains(true) }
    }

    private func service(_ keychain: Keychain) -> GoogleIntegrationsService {
        GoogleIntegrationsService(credentials: GoogleCredentialStore(
            read: { keychain.read($0) },
            write: { keychain.write($0, $1) }
        ))
    }

    @MainActor
    func testLoadingReadsOffTheMainThreadOnceAndServesFromMemory() async {
        let keychain = Keychain([
            GoogleIntegrationsService.Key.clientId: "client",
            GoogleIntegrationsService.Key.refreshToken: "refresh"
        ])
        let google = service(keychain)

        let loaded = await google.loadCredentials()
        XCTAssertEqual(loaded.clientId, "client")
        XCTAssertEqual(loaded.refreshToken, "refresh")
        XCTAssertEqual(loaded.accessToken, "")
        XCTAssertEqual(keychain.reads.count, 5)
        XCTAssertFalse(keychain.readOnMain, "Keychain reads must not run on the main thread")

        // What the page reads afterwards — including isSignedIn — comes from memory.
        XCTAssertTrue(google.isSignedIn)
        XCTAssertTrue(google.isConfigured)
        _ = await google.loadCredentials()
        XCTAssertEqual(keychain.reads.count, 5, "no second read, and misses are cached too")
    }

    @MainActor
    func testPuttingLoadedValuesBackIntoTheFieldsWritesNothing() async {
        let keychain = Keychain([GoogleIntegrationsService.Key.clientId: "client"])
        let google = service(keychain)
        let loaded = await google.loadCredentials()

        // The page's onChange handlers do exactly this when the loaded values arrive.
        google.clientId = loaded.clientId
        google.clientSecret = loaded.clientSecret
        google.accessToken = loaded.accessToken
        google.credentials.waitForWrites()
        XCTAssertTrue(keychain.writes.isEmpty)
    }

    @MainActor
    func testASetIsVisibleAtOnceAndWrittenInOrder() async {
        let keychain = Keychain()
        let google = service(keychain)
        _ = await google.loadCredentials()

        google.clientId = "a"
        google.clientId = "ab"
        google.accessToken = "token"
        XCTAssertEqual(google.clientId, "ab")
        google.credentials.waitForWrites()
        XCTAssertEqual(keychain.writes, ["google_client_id=a", "google_client_id=ab", "google_access_token=token"])

        google.signOut()
        XCTAssertFalse(google.isSignedIn)
        google.credentials.waitForWrites()
        XCTAssertEqual(keychain.writes.last, "google_access_token=")
    }

    /// A value set before a load finishes is not replaced by the older Keychain copy.
    func testALoadNeverOverwritesANewerValue() async {
        let keychain = Keychain([GoogleIntegrationsService.Key.apiKey: "old"])
        let store = GoogleCredentialStore(read: { keychain.read($0) }, write: { keychain.write($0, $1) })
        store.set("new", for: GoogleIntegrationsService.Key.apiKey)
        await store.load(keys: [GoogleIntegrationsService.Key.apiKey])
        XCTAssertEqual(store.value(for: GoogleIntegrationsService.Key.apiKey), "new")
    }

    func testTheSettingsPageNoLongerReadsSecretsSynchronously() throws {
        let source = try SourceTree.settingsViewSource()
        XCTAssertTrue(source.contains("await GoogleIntegrationsService.shared.loadCredentials()"))
        for property in ["clientId", "clientSecret", "apiKey"] {
            XCTAssertFalse(source.contains("= google.\(property)"),
                           "Settings must take \(property) from loadCredentials(), not read it on the main thread")
        }
    }
}
