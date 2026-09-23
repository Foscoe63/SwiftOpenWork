import Foundation

/// Turns build and test output into something an agent can act on.
///
/// A failing `swift build` prints thousands of lines, of which perhaps three matter. Handing the
/// raw tail to the model wastes context and buries the actual errors — it can see that something
/// failed but not reliably what or where. This extracts the diagnostics and reports them as
/// `file:line: message`, the same shape `grep` returns, so the next step is to open that line.
public enum BuildDiagnostics {

    public enum Severity: String, Sendable, Comparable {
        case error
        case warning
        case note

        /// Errors sort first — they are what blocks the build.
        private var rank: Int {
            switch self {
            case .error: return 0
            case .warning: return 1
            case .note: return 2
            }
        }
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    public struct Diagnostic: Sendable, Equatable {
        public var file: String
        public var line: Int
        public var column: Int?
        public var severity: Severity
        public var message: String

        public init(file: String, line: Int, column: Int? = nil, severity: Severity, message: String) {
            self.file = file
            self.line = line
            self.column = column
            self.severity = severity
            self.message = message
        }

        public var display: String {
            let where_ = column.map { "\(file):\(line):\($0)" } ?? "\(file):\(line)"
            return "\(where_): \(severity.rawValue): \(message)"
        }
    }

    /// `/path/File.swift:12:5: error: message` — Swift, clang, and xcodebuild all emit this.
    private static let compilerPattern = try? NSRegularExpression(
        pattern: #"^(.+?):(\d+):(?:(\d+):)?\s*(error|warning|note):\s*(.+)$"#
    )

    /// XCTest failures: `/path/FileTests.swift:42: error: -[Suite test] : XCTAssertEqual failed…`
    /// The column is absent, and the message carries the test identity.
    private static let xctestPattern = try? NSRegularExpression(
        pattern: #"^(.+?):(\d+):\s*error:\s*(-\[.+?\].*)$"#
    )

    /// swift-testing: `✘ Test "name" recorded an issue at File.swift:10:5: message`
    private static let swiftTestingPattern = try? NSRegularExpression(
        pattern: #"recorded an issue at (.+?):(\d+):(?:(\d+):)?\s*(.+)$"#
    )

    /// Parse diagnostics out of combined stdout/stderr, de-duplicated and ordered by severity.
    public static func parse(_ output: String, relativeTo root: String = "") -> [Diagnostic] {
        var found: [Diagnostic] = []
        var seen = Set<String>()

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard let diagnostic = parseLine(line, relativeTo: root) else { continue }
            // The same error is reported once per target that pulls the file in.
            let key = "\(diagnostic.file):\(diagnostic.line):\(diagnostic.severity.rawValue):\(diagnostic.message)"
            guard seen.insert(key).inserted else { continue }
            found.append(diagnostic)
        }

        return found.sorted {
            $0.severity == $1.severity
                ? ($0.file == $1.file ? $0.line < $1.line : $0.file < $1.file)
                : $0.severity < $1.severity
        }
    }

    public static func parseLine(_ line: String, relativeTo root: String = "") -> Diagnostic? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)

        // swift-testing first: its line also contains a colon-separated location that the
        // compiler pattern would misread as a message.
        if let regex = swiftTestingPattern, let m = regex.firstMatch(in: line, range: range) {
            guard let file = group(m, 1, in: line), let lineNo = group(m, 2, in: line).flatMap(Int.init) else { return nil }
            return Diagnostic(
                file: relativise(file, root: root),
                line: lineNo,
                column: group(m, 3, in: line).flatMap(Int.init),
                severity: .error,
                message: (group(m, 4, in: line) ?? "test failed").trimmingCharacters(in: .whitespaces)
            )
        }

        if let regex = xctestPattern, let m = regex.firstMatch(in: line, range: range) {
            guard let file = group(m, 1, in: line), let lineNo = group(m, 2, in: line).flatMap(Int.init) else { return nil }
            return Diagnostic(
                file: relativise(file, root: root),
                line: lineNo,
                severity: .error,
                message: (group(m, 3, in: line) ?? "").trimmingCharacters(in: .whitespaces)
            )
        }

        if let regex = compilerPattern, let m = regex.firstMatch(in: line, range: range) {
            guard let file = group(m, 1, in: line),
                  let lineNo = group(m, 2, in: line).flatMap(Int.init),
                  let severityText = group(m, 4, in: line),
                  let severity = Severity(rawValue: severityText) else { return nil }
            // Ignore lines where the "file" is obviously prose rather than a path.
            guard file.contains("/") || file.contains(".") else { return nil }
            return Diagnostic(
                file: relativise(file, root: root),
                line: lineNo,
                column: group(m, 3, in: line).flatMap(Int.init),
                severity: severity,
                message: (group(m, 5, in: line) ?? "").trimmingCharacters(in: .whitespaces)
            )
        }
        return nil
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> String? {
        guard index < match.numberOfRanges,
              let range = Range(match.range(at: index), in: line) else { return nil }
        return String(line[range])
    }

    private static func relativise(_ path: String, root: String) -> String {
        guard !root.isEmpty else { return path }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    // MARK: - Reporting

    /// A failure caused by the machine rather than the project, stated as such, so the model
    /// reports it instead of editing code that was never compiled.
    public static func environmentHint(in output: String) -> String? {
        if output.contains("requires Xcode, but active developer directory") {
            return "This is the machine's setup, not the code: no full Xcode was found to build with. "
                + "The user can fix it with `sudo xcode-select -s /Applications/Xcode.app` — tell them; do not edit code over it."
        }
        return nil
    }

    /// Render a result the model can act on: verdict first, then errors, then a bounded tail.
    public static func summarize(
        command: String,
        exitCode: Int32,
        output: String,
        root: String = "",
        maxDiagnostics: Int = 25,
        tailLines: Int = 20
    ) -> String {
        let diagnostics = parse(output, relativeTo: root)
        let errors = diagnostics.filter { $0.severity == .error }
        let warnings = diagnostics.filter { $0.severity == .warning }

        var lines: [String] = []
        if exitCode == 0 {
            lines.append("`\(command)` succeeded." + (warnings.isEmpty ? "" : " \(warnings.count) warning(s)."))
        } else {
            // "with 0 error(s)" read as a clean compile that failed for no reason. When nothing
            // parsed, the cause is in the tail below, not in the code.
            lines.append(errors.isEmpty
                ? "`\(command)` failed (exit \(exitCode)) before reporting any compiler errors."
                : "`\(command)` failed (exit \(exitCode)) with \(errors.count) error(s).")
            if let hint = environmentHint(in: output) {
                lines.append(hint)
            }
        }

        if !errors.isEmpty {
            lines.append("")
            for diagnostic in errors.prefix(maxDiagnostics) {
                lines.append("  " + diagnostic.display)
            }
            if errors.count > maxDiagnostics {
                lines.append("  … \(errors.count - maxDiagnostics) more error(s).")
            }
        }

        // Some failures produce no parseable diagnostic at all — a linker error, a crashed
        // process, a missing tool. The tail is the only thing that explains those.
        // Naming the failing tests is what makes a narrowed re-run possible; without it the model
        // has to reconstruct identities out of diagnostic text.
        let failures = failedTests(in: output)
        if exitCode != 0 && !failures.isEmpty {
            lines.append("")
            lines.append("Failing tests: " + failures.prefix(maxDiagnostics).map(\.display).joined(separator: ", "))
            lines.append("Re-run just these with run_tests(only_failing: true).")
        }

        if errors.isEmpty && exitCode != 0 {
            let tail = output.split(separator: "\n").suffix(tailLines).joined(separator: "\n")
            lines.append("")
            lines.append("No file-level diagnostics were parsed. Last \(tailLines) lines:")
            lines.append(tail)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Failing tests

    /// A test that failed, named precisely enough to run again on its own.
    public struct FailedTest: Sendable, Equatable, Hashable {
        public var suite: String?
        public var name: String

        public init(suite: String? = nil, name: String) {
            self.suite = suite
            self.name = name
        }

        public var display: String {
            guard let suite else { return name }
            return "\(suite)/\(name)"
        }
    }

    private static let xctestIdentityPattern = try? NSRegularExpression(
        pattern: #"-\[([A-Za-z_][A-Za-z_0-9.]*) ([A-Za-z_][A-Za-z_0-9]*)\]"#
    )
    private static let goFailPattern = try? NSRegularExpression(
        pattern: #"^\s*--- FAIL: ([A-Za-z_][A-Za-z_0-9/]*)"#
    )
    /// libtest's own result line, `test module::name ... FAILED`. Doc-tests print a file path and
    /// a line number in that slot, which is not something `--exact` can select, so they are skipped.
    private static let cargoFailPattern = try? NSRegularExpression(
        pattern: #"^test ([A-Za-z_][A-Za-z_0-9:]*) \.\.\. FAILED\s*$"#
    )
    private static let pytestFailPattern = try? NSRegularExpression(
        pattern: #"^FAILED ([^\s:]+::[^\s]+)"#
    )

    /// The tests that failed, in first-seen order.
    ///
    /// Only runners whose failure lines name the test unambiguously are parsed. A guessed identity
    /// is worse than none: it would re-run the wrong test and report a pass.
    public static func failedTests(in output: String) -> [FailedTest] {
        var found: [FailedTest] = []
        var seen = Set<FailedTest>()

        func add(_ test: FailedTest) {
            if seen.insert(test).inserted { found.append(test) }
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let range = NSRange(line.startIndex..., in: line)

            // XCTest names the test in both the failure diagnostic and the "failed" summary line;
            // the identity is the same either way, so match on the identity, not the line shape.
            if line.contains("error:") || line.contains("failed"),
               let regex = xctestIdentityPattern,
               let m = regex.firstMatch(in: line, range: range),
               let suite = group(m, 1, in: line), let name = group(m, 2, in: line) {
                add(FailedTest(suite: suite, name: name))
                continue
            }
            if let regex = goFailPattern, let m = regex.firstMatch(in: line, range: range),
               let name = group(m, 1, in: line) {
                add(FailedTest(name: name))
                continue
            }
            if let regex = cargoFailPattern, let m = regex.firstMatch(in: line, range: range),
               let name = group(m, 1, in: line) {
                add(FailedTest(name: name))
                continue
            }
            if let regex = pytestFailPattern, let m = regex.firstMatch(in: line, range: range),
               let name = group(m, 1, in: line) {
                add(FailedTest(name: name))
            }
        }
        return found
    }

    /// A command that runs only `failures`, or nil when this runner cannot be narrowed safely.
    ///
    /// Returning nil is the point: a filter flag that the runner silently ignores would run the
    /// whole suite while the output claimed it ran three tests, and a filter that matches nothing
    /// exits zero — a green result for tests that never ran.
    public static func rerunCommand(baseCommand: String, failures: [FailedTest]) -> String? {
        guard !failures.isEmpty else { return nil }
        let base = baseCommand.trimmingCharacters(in: .whitespaces)
        // Already narrowed by the caller; stacking filters changes the meaning unpredictably.
        guard !base.contains("--filter"), !base.contains("-run "), !base.contains("::"),
              !base.contains("-only-testing") else { return nil }

        if base.hasPrefix("xcodebuild") {
            // -only-testing takes Target/Class/method. XCTest reports the class as Module.Class,
            // and without a suite there is no target to scope to, so refuse rather than widen.
            var identifiers: [String] = []
            for failure in failures {
                guard let suite = failure.suite, suite.contains(".") else { return nil }
                identifiers.append("\(suite.replacingOccurrences(of: ".", with: "/"))/\(failure.name)")
            }
            return ([base] + identifiers.map { "-only-testing:\($0)" }).joined(separator: " ")
        }

        if base.hasPrefix("swift test") {
            // SwiftPM takes --filter repeatedly and unions the matches. The identity is a regex, so
            // the dot in a namespaced suite name must not act as a wildcard.
            let filters = failures.map { "--filter '\(escapeForRegex($0.display))'" }
            return ([base] + filters).joined(separator: " ")
        }
        if base.hasPrefix("go test") {
            let names = failures.map { escapeForRegex($0.name) }.joined(separator: "|")
            return "\(base) -run '^(\(names))$'"
        }
        if base.hasPrefix("cargo test") {
            // Filters go to libtest after `--`, and `--exact` stops `add` also selecting
            // `add_overflow`. A base that already passes libtest arguments is left alone, because
            // appending to someone else's `--` section can change what their flags mean.
            guard !base.contains(" -- "), !base.hasSuffix(" --") else { return nil }
            guard failures.allSatisfy({ $0.suite == nil && !$0.name.contains(" ") }) else { return nil }
            return "\(base) -- --exact " + failures.map { "'\($0.name)'" }.joined(separator: " ")
        }
        // `npm test` runs whatever the package's script says — Jest, Vitest, Mocha, a shell
        // script. A filter flag one of them honours another ignores, and the whole suite would
        // run under a message claiming it ran three tests. So npm stays whole-suite.
        if base.contains("pytest") {
            // pytest identities are file::test paths, already exact.
            return ([base] + failures.map { "'\($0.name)'" }).joined(separator: " ")
        }
        return nil
    }

    private static func escapeForRegex(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if "\\^$.|?*+()[]{}".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    // MARK: - Command selection

    public enum Action: String, Sendable { case build, test }

    /// The command to run for a project, chosen from the markers `WorkspaceContext` detects.
    ///
    /// Returns nil rather than guessing when the project type is unknown — a wrong build command
    /// produces a confusing failure that looks like a code problem.
    ///
    /// `root` is only needed for Xcode projects, whose command depends on the container and scheme
    /// names on disk. Without it an Xcode-only workspace falls through to nil, as before.
    public static func command(
        forProjectKinds kinds: [String],
        action: Action,
        at root: String? = nil
    ) -> String? {
        func has(_ needle: String) -> Bool { kinds.contains { $0.localizedCaseInsensitiveContains(needle) } }

        if has("Swift package") {
            return action == .build ? "swift build" : "swift test"
        }
        if has("Cargo") || has("Rust") {
            return action == .build ? "cargo build" : "cargo test"
        }
        if has("Go module") {
            return action == .build ? "go build ./..." : "go test ./..."
        }
        if has("Node") {
            return action == .build ? "npm run build" : "npm test"
        }
        if has("Python") {
            return action == .build ? nil : "python3 -m pytest"
        }
        if has("Gradle") {
            return action == .build ? "./gradlew build" : "./gradlew test"
        }
        if has("Maven") {
            return action == .build ? "mvn -q compile" : "mvn -q test"
        }
        if has("Make") {
            return action == .build ? "make" : "make test"
        }
        // Last, so a package that also ships a generated .xcodeproj keeps using SwiftPM.
        if has("Xcode"), let root {
            return xcodebuildCommand(at: root, action: action)
        }
        return nil
    }

    // MARK: - Xcode

    /// The `xcodebuild` invocation for the Xcode container in `root`, or nil when there is none.
    ///
    /// A scheme is always passed: bare `xcodebuild` builds the first target alphabetically, so a
    /// green result would not mean what the agent reports it means. Shared schemes are read from
    /// disk; when a project shares none, the container's own name is used, because xcodebuild
    /// answers a wrong scheme by listing the real ones — a self-correcting error, not a silent one.
    public static func xcodebuildCommand(
        at root: String,
        action: Action,
        fileManager: FileManager = .default
    ) -> String? {
        guard let container = xcodeContainer(at: root, fileManager: fileManager) else { return nil }

        var parts = ["xcodebuild", container.flag, quoted(container.name), "-scheme", quoted(container.scheme)]
        switch action {
        case .build:
            // -quiet drops the per-file compile chatter but keeps warnings, errors and the verdict,
            // which is the difference between fitting in the output budget and being truncated.
            parts.append(contentsOf: ["-quiet", "build"])
        case .test:
            parts.append("test")
        }
        return parts.joined(separator: " ")
    }

    /// The Xcode workspace or project directly in `root`, and the scheme to build it with.
    public static func xcodeContainer(
        at root: String,
        fileManager: FileManager = .default
    ) -> (flag: String, name: String, scheme: String)? {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else { return nil }

        let container: (flag: String, name: String)
        if let workspace = entries.first(where: { $0.hasSuffix(".xcworkspace") }) {
            container = ("-workspace", workspace)
        } else if let project = entries.first(where: { $0.hasSuffix(".xcodeproj") }) {
            container = ("-project", project)
        } else {
            return nil
        }
        let base = (container.name as NSString).deletingPathExtension
        let scheme = sharedScheme(forContainer: container.name, in: root, fileManager: fileManager) ?? base
        return (container.flag, container.name, scheme)
    }

    /// The first shared scheme of a container, preferring one named after the container itself.
    private static func sharedScheme(
        forContainer container: String,
        in root: String,
        fileManager: FileManager
    ) -> String? {
        // A workspace's schemes are often shared from the projects it wraps, not the workspace.
        var searchRoots = [(root as NSString).appendingPathComponent(container)]
        if container.hasSuffix(".xcworkspace"), let entries = try? fileManager.contentsOfDirectory(atPath: root) {
            searchRoots += entries
                .filter { $0.hasSuffix(".xcodeproj") }
                .map { (root as NSString).appendingPathComponent($0) }
        }

        var found: [String] = []
        for searchRoot in searchRoots {
            let dir = (searchRoot as NSString).appendingPathComponent("xcshareddata/xcschemes")
            let names = ((try? fileManager.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".xcscheme") }
                .map { ($0 as NSString).deletingPathExtension }
            found.append(contentsOf: names)
        }
        guard !found.isEmpty else { return nil }

        let containerBase = (container as NSString).deletingPathExtension
        return found.first { $0 == containerBase } ?? found.sorted().first
    }

    public static func quoted(_ value: String) -> String {
        value.contains(where: { $0 == " " || $0 == "'" }) ? "'\(value.replacingOccurrences(of: "'", with: #"'\''"#))'" : value
    }
}
