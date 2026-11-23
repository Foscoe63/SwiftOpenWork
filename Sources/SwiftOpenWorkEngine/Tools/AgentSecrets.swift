import Foundation
import SwiftOpenWorkStorage

/// Secrets the agent asked the user for with `request_secret`.
///
/// The model never receives a value. It learns only that `NAME` is saved; shell commands then see
/// it as the environment variable `$NAME`, and any tool result that happens to echo it is
/// redacted before the model reads it. Values live in the Keychain; only the names are kept in
/// UserDefaults so they can be listed.
public enum AgentSecrets {
    static let namesKey = "agentSecretNames"
    static let keychainPrefix = "agent-secret."
    /// Shorter values would redact ordinary words ("1", "yes") out of every result.
    static let minimumRedactableLength = 6

    /// Upper-case letters, digits and underscores, starting with a letter: a valid shell variable.
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[A-Z][A-Z0-9_]{1,63}$", options: .regularExpression) != nil
    }

    public static func names() -> [String] {
        (UserDefaults.standard.stringArray(forKey: namesKey) ?? []).sorted()
    }

    public static func has(_ name: String) -> Bool { names().contains(name) && value(for: name) != nil }

    static func value(for name: String) -> String? {
        KeychainManager.shared.getSecret(forKey: keychainPrefix + name)
    }

    @discardableResult
    public static func save(name: String, value: String) -> Bool {
        guard isValidName(name), !value.isEmpty,
              KeychainManager.shared.saveSecret(value, forKey: keychainPrefix + name) else { return false }
        var all = Set(names()); all.insert(name)
        UserDefaults.standard.set(Array(all), forKey: namesKey)
        return true
    }

    public static func remove(name: String) {
        _ = KeychainManager.shared.saveSecret("", forKey: keychainPrefix + name)
        UserDefaults.standard.set(names().filter { $0 != name }, forKey: namesKey)
    }

    /// Adds every saved secret to a shell command's environment. A name the user already set in
    /// Settings wins, so a saved secret cannot silently override a deliberate variable.
    public static func inject(into environment: inout [String: String]) {
        for name in names() where environment[name] == nil {
            if let v = value(for: name) { environment[name] = v }
        }
    }

    /// `text` with every saved value replaced by `[secret NAME]`, longest values first so one
    /// that contains another is not left half-visible.
    public static func redact(_ text: String) -> String {
        redact(text, secrets: names().compactMap { n in value(for: n).map { (n, $0) } })
    }

    static func redact(_ text: String, secrets: [(name: String, value: String)]) -> String {
        var out = text
        for (name, v) in secrets.sorted(by: { $0.value.count > $1.value.count })
        where v.count >= minimumRedactableLength && out.contains(v) {
            out = out.replacingOccurrences(of: v, with: "[secret \(name)]")
        }
        return out
    }
}
