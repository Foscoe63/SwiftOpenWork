import Foundation
import os
import SwiftOpenWorkCore

/// Cloud API keys, read from the Keychain the first time something needs one — never at launch.
///
/// `loadProviders()` used to hydrate every cloud provider's key inside `AppState.loadAll()`, on the
/// main thread, before the window existed. A Keychain read can block on securityd and, whenever the
/// app's code signature changes (every rebuild, every new release), raise an authorisation prompt
/// per item. Launch then hung with no window at all — seen live on 2026-09-17, stuck in
/// `SecItemCopyMatching` for as long as the prompt went unanswered. Someone who only uses local
/// models was prompted for keys they never use.
///
/// Now a key is read off the main thread when a request, a connection test or a model list needs it,
/// and cached — misses too, so a denied prompt is not shown again on every request.
public enum ProviderCredentials {

    private static let readerStore = OSAllocatedUnfairLock<@Sendable (String) -> String?>(initialState: { key in
        KeychainManager.shared.getSecret(forKey: key)
    })

    /// Reads a stored secret. Replaceable for tests.
    public static var reader: @Sendable (String) -> String? {
        get { readerStore.withLock { $0 } }
        set { readerStore.withLock { $0 = newValue } }
    }

    private static let cache = Cache()

    public static func keychainKey(for providerId: String) -> String { "provider_key_\(providerId)" }

    /// `provider` with its API key filled in, when it is a cloud provider whose key is not loaded.
    public static func hydrated(_ provider: ModelProvider) async -> ModelProvider {
        // Local servers can carry a key too; the in-process engines never do.
        guard provider.apiKey.isEmpty, provider.type == .cloud || (provider.kind != .omlx && provider.kind != .vmlx) else { return provider }
        var filled = provider
        if let cached = cache.value(for: provider.id) {
            filled.apiKey = cached
            return filled
        }
        let account = keychainKey(for: provider.id)
        let read = reader
        let secret = await Task.detached(priority: .userInitiated) { read(account) }.value ?? ""
        cache.store(secret, for: provider.id)
        filled.apiKey = secret
        return filled
    }

    /// The key last saved or read for this provider, or nil when none is cached.
    public static func cachedKey(for providerId: String) -> String? {
        cache.value(for: providerId)
    }

    /// Record a key the app has just saved, so the next request does not read it back.
    public static func remember(_ key: String, for providerId: String) {
        cache.store(key, for: providerId)
    }

    public static func forget(_ providerId: String) {
        cache.remove(providerId)
    }

    public static func resetCache() { cache.removeAll() }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]

        func value(for id: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return values[id]
        }

        func store(_ value: String, for id: String) {
            lock.lock(); values[id] = value; lock.unlock()
        }

        func remove(_ id: String) {
            lock.lock(); values[id] = nil; lock.unlock()
        }

        func removeAll() {
            lock.lock(); values.removeAll(); lock.unlock()
        }
    }
}
