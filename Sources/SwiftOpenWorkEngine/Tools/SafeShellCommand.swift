import Foundation

/// The allowlist behind Terminal Safety Level "Allow Safe Read-Only Commands" — the default, and
/// the level at which an allowed command runs **without asking**. So a false "safe" is arbitrary
/// code execution on a single tool call.
///
/// The previous check looked only at each segment's first word. That let through, among others:
/// `env python3 -c …` and `env sh -c …` (`env` runs any program), `rg --pre sh` (ripgrep runs the
/// preprocessor on every file), `sort -o FILE`, `uniq IN FILE`, `tree -o FILE`, `find -fprint FILE`
/// and `git log --output=FILE` (each overwrites any file), and `git branch -D` / `git remote add`.
/// It also split on spaces without regard to quotes, so a flag written `'--pre'` would not have
/// been seen by any flag check.
///
/// Now the command is tokenised the way the shell will read it, every segment must start with an
/// allowed command, and each command's flags that execute a program or write a file are refused.
/// Anything this cannot parse — unbalanced quotes, substitutions, redirections — is not safe.
public enum SafeShellCommand {

    /// Shell syntax that is never safe here, even inside quotes: redirection and substitution.
    /// Command names are not listed: every command must start with an allowlisted word, so `rm` or
    /// `curl` can only appear as an argument, where it is harmless — and matching names as text
    /// refused `rg "func (x|y)"`, because `func ` contains `nc `.
    static let refusedFragments = [">", "<(", "$(", "`", ":(){"]

    /// Commands that only read. `env`, `printenv`, `less` and `more` are deliberately absent:
    /// `env` runs other programs, `printenv` prints every secret in the environment, and the
    /// pagers can run commands.
    static let readOnlyCommands: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "pwd", "echo", "date", "whoami", "which",
        "file", "du", "df", "ps", "grep", "rg", "sort", "uniq", "uname", "sw_vers",
        "hostname", "stat", "tree", "diff", "find", "git",
    ]

    static let readOnlyGitSubcommands: Set<String> = [
        "status", "log", "diff", "show", "branch", "remote", "blame", "describe", "rev-parse",
    ]

    /// Commands whose dangerous behaviour hangs on a flag. For these an unquoted glob is refused:
    /// a repository can contain a file named `--pre=sh`, and `rg foo *` would expand to it.
    static let flagSensitiveCommands: Set<String> = ["rg", "sort", "uniq", "tree", "file", "find", "git"]

    public static func isSafe(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lowered = trimmed.lowercased()
        if refusedFragments.contains(where: { lowered.contains($0) }) { return false }
        guard let segments = tokenize(trimmed), !segments.isEmpty else { return false }
        return segments.allSatisfy { words in
            if let head = words.first?.text, flagSensitiveCommands.contains(head),
               words.contains(where: \.hasUnquotedGlob) {
                return false
            }
            return isSafeSegment(words.map(\.text))
        }
    }

    /// A word as the shell will pass it, and whether the shell would glob-expand it first.
    struct Word: Equatable {
        var text: String
        var hasUnquotedGlob: Bool
    }

    static func isSafeSegment(_ tokens: [String]) -> Bool {
        guard let head = tokens.first, readOnlyCommands.contains(head) else { return false }
        let args = Array(tokens.dropFirst())
        switch head {
        case "git":
            return isSafeGit(args)
        case "find":
            // -exec/-execdir/-ok/-okdir run programs; -delete deletes; -fprint* and -fls write files.
            return !args.contains { arg in
                arg == "-delete" || arg == "-fls"
                    || arg.hasPrefix("-exec") || arg.hasPrefix("-ok") || arg.hasPrefix("-fprint")
            }
        case "rg":
            // --pre and --pre-glob run a program on every file searched.
            return !args.contains { $0.hasPrefix("--pre") }
        case "sort":
            // -o writes the output file; --compress-program runs one.
            return !args.contains { arg in
                arg.hasPrefix("--output") || arg.hasPrefix("--compress-program")
                    || (isShortOptionCluster(arg) && arg.contains("o"))
            }
        case "tree":
            return !args.contains { $0 == "-o" || $0.hasPrefix("--output") }
        case "file":
            // -C compiles a magic file, writing it.
            return !args.contains { $0 == "-C" || (isShortOptionCluster($0) && $0.contains("C")) || $0 == "--compile" }
        case "uniq":
            return uniqOperands(args).count <= 1
        case "hostname":
            // With an operand it sets the name.
            return args.allSatisfy { $0.hasPrefix("-") }
        case "date":
            // An operand, or -s, sets the clock.
            return !args.contains { $0 == "-s" } && args.allSatisfy { $0.hasPrefix("-") || $0.hasPrefix("+") }
        default:
            return true
        }
    }

    /// Git runs programs named in a repository's own `.git/config`: `diff.external` and textconv
    /// drivers for `diff`/`log`/`show`, and `core.fsmonitor` for nearly everything, `status`
    /// included. A repository someone else wrote can therefore make "read-only" git run code.
    /// Under the safe-only level these are switched off for the command that is about to run.
    public static func hardenedForSafeLevel(_ command: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\bgit\s+(diff|log|show)\b"#) else { return command }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        return regex.stringByReplacingMatches(
            in: command, range: range, withTemplate: "git $1 --no-ext-diff --no-textconv"
        )
    }

    /// Environment settings that override the repository's config for git, which reads these after
    /// `.git/config`.
    public static let gitHardeningEnvironment: [String: String] = [
        "GIT_CONFIG_COUNT": "2",
        "GIT_CONFIG_KEY_0": "core.fsmonitor", "GIT_CONFIG_VALUE_0": "false",
        "GIT_CONFIG_KEY_1": "diff.external", "GIT_CONFIG_VALUE_1": "",
    ]

    static func isSafeGit(_ args: [String]) -> Bool {
        // `git -C dir …`, `git -c key=value …` and other global options come before the
        // subcommand; none are allowed, so the subcommand must come first.
        guard let sub = args.first, readOnlyGitSubcommands.contains(sub) else { return false }
        let rest = args.dropFirst()
        // --output writes a file; --ext-diff and --textconv run configured programs.
        if rest.contains(where: { $0.hasPrefix("--output") || $0 == "--ext-diff" || $0 == "--textconv" }) { return false }
        switch sub {
        case "branch":
            // Listing only: any name would create, and -d/-D/-m/-c would delete, rename or copy.
            let listing: Set<String> = ["-a", "-r", "-v", "-vv", "-l", "--list", "--all", "--remotes", "--show-current", "--verbose"]
            return rest.allSatisfy { listing.contains($0) }
        case "remote":
            return rest.allSatisfy { $0 == "-v" || $0 == "--verbose" }
        default:
            return true
        }
    }

    /// `-abc`, not `--long` and not a lone `-`.
    static func isShortOptionCluster(_ arg: String) -> Bool {
        arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.count > 1
    }

    /// `uniq`'s file operands; a second one is an output file it overwrites.
    static func uniqOperands(_ args: [String]) -> [String] {
        var operands: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if arg == "-f" || arg == "-s" || arg == "--skip-fields" || arg == "--skip-chars" { skipNext = true; continue }
            if arg.hasPrefix("-") && arg != "-" { continue }
            operands.append(arg)
        }
        return operands
    }

    /// Split into commands on unquoted `;`, `|`, `&` and newlines, and each command into words
    /// with quotes and backslashes removed, as the shell would. Nil when quotes do not balance.
    static func tokenize(_ command: String) -> [[Word]]? {
        var segments: [[Word]] = []
        var tokens: [Word] = []
        var current = ""
        var globbed = false
        var inWord = false
        var quote: Character?
        var escaped = false

        func endWord() {
            if inWord { tokens.append(Word(text: current, hasUnquotedGlob: globbed)) }
            current = ""
            globbed = false
            inWord = false
        }
        func endSegment() {
            endWord()
            if !tokens.isEmpty { segments.append(tokens) }
            tokens = []
        }

        for ch in command {
            if escaped {
                current.append(ch)
                inWord = true
                escaped = false
                continue
            }
            if let q = quote {
                if ch == q {
                    quote = nil
                } else if ch == "\\" && q == "\"" {
                    escaped = true
                } else {
                    current.append(ch)
                }
                continue
            }
            switch ch {
            case "\\":
                escaped = true
            case "'", "\"":
                quote = ch
                inWord = true
            case ";", "|", "&", "\n", "\r":
                endSegment()
            case " ", "\t":
                endWord()
            default:
                if ch == "*" || ch == "?" || ch == "[" { globbed = true }
                current.append(ch)
                inWord = true
            }
        }
        guard quote == nil, !escaped else { return nil }
        endSegment()
        return segments
    }
}
