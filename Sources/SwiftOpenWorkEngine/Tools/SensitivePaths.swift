import Foundation

/// Places whose contents should not reach a model without a person saying so.
///
/// Reads never needed approval, and the default authorised folder was the whole home directory,
/// so `file_read ~/.ssh/id_ed25519` — or `cat` of it, which the safe-shell list allows — put a
/// private key into the conversation: sent to the model provider, and saved in `sessions.json`.
/// Closing the ways *out* (`fetch_url`, the shell list) does not undo that. So reading any of these
/// asks first, in the file tools and in the shell.
public enum SensitivePaths {

    /// Relative to the home directory. A folder covers everything under it.
    static let homeLocations: [String] = [
        ".ssh", ".aws", ".gnupg", ".azure", ".kube", ".docker/config.json",
        ".config/gh", ".config/gcloud", ".config/op", ".password-store",
        ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".gem/credentials", ".cargo/credentials",
        ".cargo/credentials.toml", ".vault-token", ".terraform.d/credentials.tfrc.json",
        ".zsh_history", ".bash_history", ".history", ".python_history", ".node_repl_history", ".psql_history",
        "Library/Keychains", "Library/Cookies", "Library/Mail", "Library/Messages", "Library/Safari",
        "Library/Application Support/Google/Chrome", "Library/Application Support/BraveSoftware",
        "Library/Application Support/Firefox", "Library/Application Support/Microsoft Edge",
        "Library/Application Support/Arc", "Library/Application Support/com.apple.TCC",
        "Library/Group Containers/group.com.apple.notes",
        "Library/Application Support/SwiftOpenWork",
    ]

    /// File names that hold keys or secrets wherever they are, outside the workspace. Inside it
    /// they are the project's own, and reading `.env` to debug a config is ordinary work.
    static func isSecretFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == ".env" || lower.hasPrefix(".env.") { return true }
        if lower.hasPrefix("id_rsa") || lower.hasPrefix("id_ed25519") || lower.hasPrefix("id_ecdsa") || lower.hasPrefix("id_dsa") {
            return true
        }
        return [".pem", ".p12", ".pfx", ".key", ".keychain", ".keychain-db", ".mobileprovision", ".p8"]
            .contains { lower.hasSuffix($0) }
    }

    /// Why reading `path` needs approval, or nil. Relative paths resolve against the workspace.
    public static func reason(forReading path: String, workspaceRoot: String, home: String = NSHomeDirectory()) -> String? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        guard !trimmed.isEmpty else { return nil }
        let absolute = trimmed.hasPrefix("~") ? home + trimmed.dropFirst()
            : trimmed.hasPrefix("/") ? trimmed
            : (workspaceRoot as NSString).appendingPathComponent(trimmed)
        let resolved = ToolExecutionEngine.canonicalPath(absolute)
        let homeReal = ToolExecutionEngine.canonicalPath(home)
        let workspace = workspaceRoot.isEmpty ? "" : ToolExecutionEngine.canonicalPath(workspaceRoot)
        let insideWorkspace = !workspace.isEmpty && (resolved == workspace || resolved.hasPrefix(workspace + "/"))

        for location in homeLocations {
            let protected = homeReal + "/" + location
            if resolved == protected || resolved.hasPrefix(protected + "/") {
                return "Reads \(displayPath(resolved, home: homeReal)), which can hold passwords, keys or private messages. Whatever is read is sent to the model."
            }
        }
        if !insideWorkspace, isSecretFileName((resolved as NSString).lastPathComponent) {
            return "Reads \(displayPath(resolved, home: homeReal)), a key or secrets file outside the workspace. Whatever is read is sent to the model."
        }
        return nil
    }

    /// For a recursive search rooted at `path`: it reads every file below, so a root that
    /// contains a sensitive location — the home folder, `/`, `~/Library` — needs approval too.
    public static func reason(forSearchingUnder path: String, workspaceRoot: String, home: String = NSHomeDirectory()) -> String? {
        if let direct = reason(forReading: path, workspaceRoot: workspaceRoot, home: home) { return direct }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        let absolute = trimmed.isEmpty ? workspaceRoot
            : trimmed.hasPrefix("/") ? trimmed
            : trimmed.hasPrefix("~") ? home + trimmed.dropFirst()
            : (workspaceRoot as NSString).appendingPathComponent(trimmed)
        let root = ToolExecutionEngine.canonicalPath(absolute)
        let homeReal = ToolExecutionEngine.canonicalPath(home)
        let covers = homeLocations.contains { location in
            let protected = homeReal + "/" + location
            return root == "/" || protected.hasPrefix(root + "/")
        }
        return covers
            ? "Searches everything under \(displayPath(root, home: homeReal)), including folders that hold keys and passwords. Whatever matches is sent to the model."
            : nil
    }

    /// Why a shell command needs approval because of what it would read, or nil.
    ///
    /// Every word that looks like a path is checked. Globs are expanded by the shell after this
    /// runs, so a word outside the workspace that contains `*`, `?` or `[` asks too: `~/.s?h/*`
    /// would otherwise slip past a literal check.
    public static func reason(forShellCommand command: String, workspaceRoot: String, home: String = NSHomeDirectory()) -> String? {
        guard let segments = SafeShellCommand.tokenize(command) else { return nil }
        let recursiveSearchers: Set<String> = ["grep", "rg", "egrep", "fgrep", "ag", "ack"]
        for words in segments {
            guard let head = words.first?.text else { continue }
            let isRecursiveSearch = recursiveSearchers.contains(head)
                && (head == "rg" || words.contains { $0.text == "-r" || $0.text == "-R" || $0.text.hasPrefix("--recursive") || ($0.text.hasPrefix("-") && !$0.text.hasPrefix("--") && ($0.text.contains("r") || $0.text.contains("R"))) })
            for word in words.dropFirst() where looksLikePath(word.text) {
                if isRecursiveSearch, let reason = reason(forSearchingUnder: word.text, workspaceRoot: workspaceRoot, home: home) {
                    return reason
                }
                if let reason = reason(forReading: word.text, workspaceRoot: workspaceRoot, home: home) {
                    return reason
                }
                if word.hasUnquotedGlob, isOutsideWorkspace(word.text, workspaceRoot: workspaceRoot, home: home) {
                    return "Reads \(word.text) outside the workspace, and a pattern cannot be checked before the shell expands it. Whatever is read is sent to the model."
                }
            }
        }
        return nil
    }

    static func looksLikePath(_ word: String) -> Bool {
        !word.hasPrefix("-") && (word.hasPrefix("/") || word.hasPrefix("~") || word.hasPrefix(".") || word.contains("/")
            || isSecretFileName((word as NSString).lastPathComponent))
    }

    static func isOutsideWorkspace(_ word: String, workspaceRoot: String, home: String) -> Bool {
        guard word.hasPrefix("/") || word.hasPrefix("~") || word.hasPrefix("..") else { return false }
        let absolute = word.hasPrefix("~") ? home + word.dropFirst()
            : word.hasPrefix("/") ? word
            : (workspaceRoot as NSString).appendingPathComponent(word)
        let resolved = ToolExecutionEngine.canonicalPath(absolute)
        let workspace = ToolExecutionEngine.canonicalPath(workspaceRoot)
        return !(resolved == workspace || resolved.hasPrefix(workspace + "/"))
    }

    static func displayPath(_ path: String, home: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~/" + path.dropFirst(home.count + 1) : path
    }
}
