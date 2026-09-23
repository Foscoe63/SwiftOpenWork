import Foundation
import os

/// A language server the app knows how to run, and which files it answers for.
public struct LanguageServerSpec: Sendable, Equatable {

    /// How to tell that the server has finished indexing, so index-backed answers are complete.
    public enum Readiness: Sendable, Equatable {
        /// `workspace/synchronize` (sourcekit-lsp): the server itself blocks until indexing is done.
        case synchronizeRequest
        /// No such request: wait for work-done progress to end and stay quiet.
        case progressQuiet
    }

    /// One way to launch the server.
    public struct Command: Sendable, Equatable {
        public var executable: String
        public var arguments: [String]
        /// Checked inside the project root before the search path, e.g. `node_modules/.bin/tsc`:
        /// a project's own toolchain is the one its code is written against.
        public var projectPaths: [String]
        public var requirement: Requirement

        public init(_ executable: String, arguments: [String] = [], projectPaths: [String] = [], requirement: Requirement = .none) {
            self.executable = executable
            self.arguments = arguments
            self.projectPaths = projectPaths
            self.requirement = requirement
        }
    }

    /// A condition a command needs besides existing.
    public enum Requirement: Sendable, Equatable {
        case none
        /// TypeScript 7 moved to a native compiler with a built-in server (`tsc --lsp`) and no
        /// longer ships the `tsserver` that typescript-language-server drives. So the version
        /// decides which command works. For `.typeScriptBelow`, a project without TypeScript of
        /// its own passes, and the server reports for itself if it finds none.
        case typeScriptAtLeast(Int)
        case typeScriptBelow(Int)
    }

    public var id: String
    /// File extension (lowercased, no dot) to LSP language identifier.
    public var languages: [String: String]
    /// Launch commands, tried in order.
    public var commands: [Command]
    /// Files whose presence in a directory makes it this server's project root.
    public var rootMarkers: [String]
    public var readiness: Readiness
    /// Shown when the server is not installed, so the agent can tell the user what to do.
    public var installHint: String
    /// JSON sent as `initializationOptions`, for servers that take settings that way.
    public var initializationOptions: String? = nil

    public func languageId(forPath path: String) -> String? {
        languages[(path as NSString).pathExtension.lowercased()]
    }
}

/// Which server answers for a file, and where it is.
///
/// A server is only chosen when its project root is found. Without one, most servers still
/// answer — with results from the open file alone, which look exactly like complete results.
/// sourcekit-lsp on a bare `.xcodeproj` returns a rename touching only the declaring file. So a
/// missing root is a refusal with a reason, never a degraded answer.
public enum LanguageServerCatalog {

    public static let sourceKit = LanguageServerSpec(
        id: "sourcekit-lsp",
        languages: ["swift": "swift", "c": "c", "h": "c", "m": "objective-c", "mm": "objective-cpp",
                    "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp"],
        commands: [LanguageServerSpec.Command("sourcekit-lsp")],
        rootMarkers: ["Package.swift", "buildServer.json", "compile_commands.json"],
        readiness: .synchronizeRequest,
        installHint: "Install Xcode, or a Swift toolchain that includes sourcekit-lsp.",
        // Lets `workspace/synchronize` also wait for build settings. Without it the request
        // returns before a build server has answered, and the first query after opening a file
        // gets single-file results.
        initializationOptions: #"{"experimentalFeatures":["synchronize-for-build-system-updates"]}"#
    )

    public static let all: [LanguageServerSpec] = [
        sourceKit,
        LanguageServerSpec(
            id: "clangd",
            languages: ["c": "c", "h": "c", "m": "objective-c", "mm": "objective-cpp",
                        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp"],
            commands: [LanguageServerSpec.Command("clangd")],
            rootMarkers: ["compile_commands.json", "compile_flags.txt", ".clangd"],
            readiness: .progressQuiet,
            installHint: "Install clangd (brew install llvm) and generate compile_commands.json."
        ),
        LanguageServerSpec(
            id: "typescript",
            languages: ["ts": "typescript", "tsx": "typescriptreact", "js": "javascript",
                        "jsx": "javascriptreact", "mjs": "javascript", "cjs": "javascript"],
            commands: [
                LanguageServerSpec.Command("tsc", arguments: ["--lsp", "--stdio"], projectPaths: ["node_modules/.bin/tsc"],
                        requirement: .typeScriptAtLeast(7)),
                LanguageServerSpec.Command("typescript-language-server", arguments: ["--stdio"],
                        projectPaths: ["node_modules/.bin/typescript-language-server"], requirement: .typeScriptBelow(7)),
            ],
            rootMarkers: ["tsconfig.json", "jsconfig.json", "package.json"],
            readiness: .progressQuiet,
            installHint: "Install TypeScript 7 or later in the project (npm install -D typescript), which includes a language server. With TypeScript 5 or 6, install typescript-language-server as well."
        ),
        LanguageServerSpec(
            id: "pyright",
            languages: ["py": "python"],
            commands: [
                LanguageServerSpec.Command("basedpyright-langserver", arguments: ["--stdio"]),
                LanguageServerSpec.Command("pyright-langserver", arguments: ["--stdio"]),
            ],
            rootMarkers: ["pyrightconfig.json", "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt"],
            readiness: .progressQuiet,
            installHint: "Install it with: npm install -g pyright"
        ),
        LanguageServerSpec(
            id: "rust-analyzer",
            languages: ["rs": "rust"],
            commands: [LanguageServerSpec.Command("rust-analyzer")],
            rootMarkers: ["Cargo.toml"],
            readiness: .progressQuiet,
            installHint: "Install it with: rustup component add rust-analyzer"
        ),
        LanguageServerSpec(
            id: "gopls",
            languages: ["go": "go"],
            commands: [LanguageServerSpec.Command("gopls")],
            rootMarkers: ["go.mod", "go.work"],
            readiness: .progressQuiet,
            installHint: "Install it with: go install golang.org/x/tools/gopls@latest"
        ),
    ]

    /// A server that can answer for a file, ready to launch.
    public struct Resolution: Sendable, Equatable {
        public var spec: LanguageServerSpec
        /// The project root the server is started in.
        public var root: String
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]
    }

    public enum Unavailable: Error, LocalizedError, Equatable {
        case unsupportedFileType(String)
        case noProjectRoot(server: String, markers: [String])
        /// An Xcode project with no Package.swift: sourcekit-lsp needs a build server for it.
        case xcodeProjectNeedsSetup(directory: String)
        case notInstalled(server: String, hint: String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFileType(let ext):
                return "No language server handles .\(ext) files. Use grep or find_symbol instead."
            case .noProjectRoot(let server, let markers):
                return "\(server) needs a project root (one of \(markers.joined(separator: ", "))) between the file and the workspace folder. Without one its answers would cover the open file only."
            case .xcodeProjectNeedsSetup(let directory):
                return "\(directory) is an Xcode project without a Package.swift, so sourcekit-lsp has no build settings for it and would answer from one file at a time. Run setup_xcode_language_server once (it writes buildServer.json and builds the scheme), then ask again."
            case .notInstalled(let server, let hint):
                return "\(server) is not installed. \(hint)"
            }
        }
    }

    /// Choose the server for `file`, which must be inside `workspaceRoot`.
    ///
    /// Candidates are tried in catalog order. A server that handles the extension but has no root
    /// or is not installed is skipped in favour of the next, and the first reason is reported if
    /// none qualifies — that reason is the most useful one, since the catalog lists the preferred
    /// server first.
    public static func resolve(
        file: String,
        workspaceRoot: String,
        specs: [LanguageServerSpec] = all,
        locator: ExecutableLocator = ExecutableLocator()
    ) -> Result<Resolution, Unavailable> {
        let ext = (file as NSString).pathExtension.lowercased()
        let candidates = specs.filter { $0.languages[ext] != nil }
        guard !candidates.isEmpty else { return .failure(.unsupportedFileType(ext.isEmpty ? "(none)" : ext)) }

        var firstReason: Unavailable?
        for spec in candidates {
            guard let root = projectRoot(for: file, workspaceRoot: workspaceRoot, markers: spec.rootMarkers, fileExists: locator.fileExists) else {
                if spec.id == sourceKit.id,
                   let directory = XcodeBuildServer.xcodeProjectDirectory(containing: file, workspaceRoot: workspaceRoot, listDirectory: locator.listDirectory) {
                    firstReason = firstReason ?? .xcodeProjectNeedsSetup(directory: CodeIntelligence.relativePath(directory, workspaceRoot: workspaceRoot))
                } else {
                    firstReason = firstReason ?? .noProjectRoot(server: spec.id, markers: spec.rootMarkers)
                }
                continue
            }
            guard let located = locator.locate(spec, projectRoot: root) else {
                firstReason = firstReason ?? .notInstalled(server: spec.id, hint: spec.installHint)
                continue
            }
            return .success(Resolution(spec: spec, root: root, executable: located.executable,
                                       arguments: located.arguments, environment: located.environment))
        }
        return .failure(firstReason!)
    }

    /// The nearest directory from the file up to the workspace root that holds a marker.
    ///
    /// The nearest, so a package nested in a monorepo gets its own server. Never above the
    /// workspace root: a marker in a parent folder belongs to some other project.
    public static func projectRoot(for file: String, workspaceRoot: String, markers: [String], fileExists: (String) -> Bool) -> String? {
        let root = standardized(workspaceRoot)
        var directory = (standardized(file) as NSString).deletingLastPathComponent
        guard directory == root || directory.hasPrefix(root + "/") else { return nil }
        while true {
            if markers.contains(where: { fileExists((directory as NSString).appendingPathComponent($0)) }) {
                return directory
            }
            if directory == root || directory == "/" { return nil }
            directory = (directory as NSString).deletingLastPathComponent
        }
    }

    /// Absolute, `..`-free and symlink-resolved, so `/var/…` and `/private/var/…` compare equal —
    /// servers report whichever spelling their index recorded.
    public static func standardized(_ path: String) -> String {
        let value = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return value.count > 1 && value.hasSuffix("/") ? String(value.dropLast()) : value
    }
}

/// Finds server executables the way a user's shell would, without a shell.
///
/// An app launched from the Finder inherits a minimal PATH, so the places package managers install
/// to are searched explicitly, and the search path is passed on to the server — Node-based
/// servers are `#!/usr/bin/env node` scripts that fail without it.
public struct ExecutableLocator: Sendable {
    public var environment: [String: String]
    public var home: String
    public var isExecutable: @Sendable (String) -> Bool
    public var fileExists: @Sendable (String) -> Bool
    public var listDirectory: @Sendable (String) -> [String]
    public var bundleVersion: @Sendable (String) -> String?
    /// Where `xcode-select` points, which is what `xcode-select -p` reads.
    public var selectedDeveloperDirectory: @Sendable () -> String?
    /// The `version` field of a package.json, or nil.
    public var packageVersion: @Sendable (String) -> String?
    /// The path with symlinks resolved, so `node_modules/.bin/tsc` leads to its package.
    public var resolveSymlinks: @Sendable (String) -> String
    /// Whether a command exits successfully, within a few seconds.
    public var succeeds: @Sendable (String, [String]) -> Bool

    public init() {
        self.environment = ProcessInfo.processInfo.environment
        self.home = NSHomeDirectory()
        self.isExecutable = { FileManager.default.isExecutableFile(atPath: $0) }
        self.fileExists = { FileManager.default.fileExists(atPath: $0) }
        self.listDirectory = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
        self.bundleVersion = { app in
            (NSDictionary(contentsOfFile: app + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String)
        }
        self.selectedDeveloperDirectory = {
            try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")
        }
        self.packageVersion = { path in
            guard let data = FileManager.default.contents(atPath: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object["version"] as? String
        }
        self.resolveSymlinks = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        self.succeeds = { executable, arguments in
            RustupProbe.cachedResult(executable: executable, arguments: arguments)
        }
    }

    public init(
        environment: [String: String],
        home: String,
        isExecutable: @escaping @Sendable (String) -> Bool,
        fileExists: @escaping @Sendable (String) -> Bool,
        listDirectory: @escaping @Sendable (String) -> [String] = { _ in [] },
        bundleVersion: @escaping @Sendable (String) -> String? = { _ in nil },
        selectedDeveloperDirectory: @escaping @Sendable () -> String? = { nil },
        packageVersion: @escaping @Sendable (String) -> String? = { _ in nil },
        resolveSymlinks: @escaping @Sendable (String) -> String = { $0 },
        succeeds: @escaping @Sendable (String, [String]) -> Bool = { _, _ in true }
    ) {
        self.environment = environment
        self.home = home
        self.isExecutable = isExecutable
        self.fileExists = fileExists
        self.listDirectory = listDirectory
        self.bundleVersion = bundleVersion
        self.selectedDeveloperDirectory = selectedDeveloperDirectory
        self.packageVersion = packageVersion
        self.resolveSymlinks = resolveSymlinks
        self.succeeds = succeeds
    }

    /// Whether `candidate` is a rustup proxy for a component that is not installed.
    ///
    /// rustup puts a `rust-analyzer` proxy in `~/.cargo/bin` whether or not the component is
    /// installed. Run without it, the proxy exits with "Unknown binary 'rust-analyzer' in official
    /// toolchain", so a machine with rustup and no rust-analyzer looked like it had one — the
    /// request then failed after launching it. Seen on the CI runner. A proxy sits beside `rustup`,
    /// and `rustup which` answers whether the component really exists.
    public func isInertRustupProxy(_ candidate: String) -> Bool {
        let directory = (candidate as NSString).deletingLastPathComponent
        let name = (candidate as NSString).lastPathComponent
        let rustup = directory + "/rustup"
        guard name != "rustup", isExecutable(rustup) else { return false }
        return !succeeds(rustup, ["which", name])
    }

    public var searchDirectories: [String] {
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            home + "/.local/bin", home + "/.cargo/bin", home + "/go/bin", home + "/.swiftly/bin",
            home + "/.npm-global/bin", home + "/.volta/bin", home + "/.bun/bin",
        ]
        var seen = Set<String>()
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public struct Located: Equatable {
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]
    }

    /// The first command of `spec` that exists and meets its requirement. `projectRoot` enables
    /// project-local executables and version checks against the project's own packages.
    /// An executable by name on the search path.
    public func executable(named name: String) -> String? {
        searchDirectories.map { $0 + "/" + name }.first(where: isExecutable)
    }

    public func locate(_ spec: LanguageServerSpec, projectRoot: String? = nil) -> Located? {
        var environment = self.environment
        environment["PATH"] = searchDirectories.joined(separator: ":")
        if spec.id == LanguageServerCatalog.sourceKit.id,
           let (binary, developerDir) = sourceKitInXcode() {
            environment["DEVELOPER_DIR"] = developerDir
            return Located(executable: binary, arguments: [], environment: environment)
        }
        let projectTypeScript = projectRoot.flatMap { root in
            packageVersion(root + "/node_modules/typescript/package.json").flatMap(Self.majorVersion)
        }
        for command in spec.commands {
            var candidates = (projectRoot.map { root in command.projectPaths.map { root + "/" + $0 } } ?? [])
            candidates += searchDirectories.map { $0 + "/" + command.executable }
            for candidate in candidates where isExecutable(candidate) && !isInertRustupProxy(candidate) {
                guard meets(command.requirement, executable: candidate, projectTypeScript: projectTypeScript) else { continue }
                return Located(executable: candidate, arguments: command.arguments, environment: environment)
            }
        }
        if spec.id == LanguageServerCatalog.sourceKit.id {
            let tools = "/Library/Developer/CommandLineTools/usr/bin/sourcekit-lsp"
            if isExecutable(tools) { return Located(executable: tools, arguments: [], environment: environment) }
        }
        return nil
    }

    private func meets(_ requirement: LanguageServerSpec.Requirement, executable: String, projectTypeScript: Int?) -> Bool {
        switch requirement {
        case .none:
            return true
        case .typeScriptAtLeast(let major):
            // `tsc` belongs to the TypeScript package it is installed from: bin/tsc inside it.
            let package = ((resolveSymlinks(executable) as NSString).deletingLastPathComponent as NSString)
                .deletingLastPathComponent + "/package.json"
            guard let version = packageVersion(package).flatMap(Self.majorVersion) else { return false }
            return version >= major
        case .typeScriptBelow(let major):
            return projectTypeScript.map { $0 < major } ?? true
        }
    }

    public static func majorVersion(_ version: String) -> Int? {
        Int(version.split(separator: ".").first ?? "")
    }

    /// sourcekit-lsp from an Xcode, with the developer directory it belongs to.
    ///
    /// An explicit `DEVELOPER_DIR` wins, then the Xcode `xcode-select` points at, then the newest
    /// installed Xcode by version. The Command Line Tools are deliberately not preferred: their
    /// SwiftPM can crash compiling manifests (see HANDOFF, Environment gotchas), and a server that
    /// cannot load the package answers from single files.
    public func sourceKitInXcode() -> (String, String)? {
        func binary(in developer: String) -> String? {
            let path = developer + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"
            return isExecutable(path) ? path : nil
        }
        if let explicit = environment["DEVELOPER_DIR"], let found = binary(in: explicit) {
            return (found, explicit)
        }
        if let selected = selectedDeveloperDirectory(),
           selected.contains(".app/"), let found = binary(in: selected) {
            return (found, selected)
        }
        let xcodes = listDirectory("/Applications")
            .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
            .map { "/Applications/" + $0 }
            .sorted { Self.isNewer(bundleVersion($0), than: bundleVersion($1)) }
        for app in xcodes {
            let developer = app + "/Contents/Developer"
            if let found = binary(in: developer) { return (found, developer) }
        }
        return nil
    }

    /// The Xcode developer directory to run build commands under, when the system would pick the
    /// Command Line Tools instead — nil when no override is needed or none is possible.
    ///
    /// `xcode-select` pointing at the Command Line Tools with Xcode installed is common (installing
    /// the tools after Xcode does it), and `xcodebuild` then refuses to run at all: "tool
    /// 'xcodebuild' requires Xcode, but active developer directory … is a command line tools
    /// instance". An agent cannot run `sudo xcode-select -s`, so every Xcode project build failed
    /// with nothing it could do. `DEVELOPER_DIR` is the per-process equivalent and needs no rights.
    public func xcodeDeveloperDirectoryOverride() -> String? {
        if let explicit = environment["DEVELOPER_DIR"], !explicit.isEmpty { return nil }
        if let selected = selectedDeveloperDirectory(), selected.contains(".app/") { return nil }
        let xcodes = listDirectory("/Applications")
            .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
            .map { "/Applications/" + $0 }
            .sorted { Self.isNewer(bundleVersion($0), than: bundleVersion($1)) }
        return xcodes
            .map { $0 + "/Contents/Developer" }
            .first { isExecutable($0 + "/usr/bin/xcodebuild") }
    }

    /// Numeric version comparison, so 26.10 beats 26.9. A missing version sorts last.
    public static func isNewer(_ lhs: String?, than rhs: String?) -> Bool {
        guard let lhs else { return false }
        guard let rhs else { return true }
        return lhs.compare(rhs, options: .numeric) == .orderedDescending
    }
}


/// Runs `rustup which …` once per executable and remembers the answer.
public enum RustupProbe {
    private static let results = OSAllocatedUnfairLock(initialState: [String: Bool]())

    public static func cachedResult(executable: String, arguments: [String]) -> Bool {
        let key = ([executable] + arguments).joined(separator: " ")
        if let known = results.withLock({ $0[key] }) { return known }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        var ok = false
        if (try? process.run()) != nil {
            if finished.wait(timeout: .now() + 5) == .timedOut {
                process.terminate()
            } else {
                ok = process.terminationStatus == 0
            }
        }
        let answer = ok
        results.withLock { $0[key] = answer }
        return answer
    }
}
