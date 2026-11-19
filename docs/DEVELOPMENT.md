# Development

Architecture, building from source, testing and releasing. See the [README](../README.md) for the overview.

## Architecture

```text
SwiftOpenWork/
├── Package.swift / Package.resolved   # SPM deps
├── project.yml                        # XcodeGen
├── SwiftOpenWork.xcodeproj
├── Resources/                         # App icon & assets
├── Tests/
├── Evals/                             # coding tasks for the eval harness
└── Sources/                 # one folder per module; see "Modules" below
    ├── SwiftOpenWorkCore/   # library, Swift 6 language mode
    │   ├── Models/          # Agent, Workspace, Session, SessionTodo, Settings,
    │   │                    # ProviderSelection, InlineFileDiff, ToolSchemaCatalog,
    │   │                    # GroupChat (addressing, handoffs, per-speaker history)
    │   ├── Providers/       # LLMProviderClient protocol, stream chunks,
    │   │                    # InProcessModelEngine, LocalGenerationGate,
    │   │                    # ReasoningChannel, ImageTransport
    │   └── Utils/           # AsyncDeadline (timeouts for uncancellable work),
    │                        # AppLog (verbose logging, gated by the setting),
    │                        # LaunchAtLogin (SMAppService), ShellEnvironment
    ├── SwiftOpenWorkStorage/ # library, Swift 6: persistence, Keychain, provider
    │                        # credentials, 1.1 → 1.2 identity migration
    ├── SwiftOpenWorkLocalInference/ # library: NativeMLXService, LocalMLXEngine,
    │                        # MLXSessionReuse — the only module that links
    │                        # MLX / Hugging Face / Transformers
    ├── SwiftOpenWorkEngine/ # library; reaches the app only through EngineHost,
    │                        # and MLX only through LocalInferenceRegistry
    │   ├── ACP/             # Agent Client Protocol client: ACPConnection (JSON-RPC
    │   │                    # over stdio), ACPAgentRunner, session pool
    │   ├── Agents/          # AgentRunner, SubAgentExecutor, approvals, AuditLog,
    │   │                    # ContextCompactor, ContextMeter,
    │   │                    # TurnCompletionNotifier
    │   ├── Automations/     # AutomationSchedule, CronExpression, LoopCheckCommand
    │   ├── Editor/          # EditorWorkspace, ProjectSearchModel, syntax
    │   │                    # highlighter, ghost-text
    │   ├── Preview/         # DevServerManager, PreviewController, PreviewLauncher,
    │   │                    # StaticFileServer
    │   ├── Providers/       # OpenAI, Anthropic, Ollama, ProviderRouter
    │   ├── LSP/             # LSPConnection (JSON-RPC), LanguageServerCatalog,
    │   │                    # LanguageServerSession/Pool, FileChangeWatcher,
    │   │                    # CodeIntelligence, SemanticRename, XcodeBuildServer
    │   ├── Eval/            # EvalHarness (tasks scored by a command; see Evals/)
    │   ├── Server/          # LocalAPIServer: OpenAI / Anthropic compatible endpoint
    │   │                    # for the loaded model (loopback, bearer key)
    │   ├── Tools/           # Execution, CodeSearch, GitTools, BuildDiagnostics,
    │   │                    # FileCheckpointStore, SessionCheckpointStore, SymbolRename,
    │   │                    # LiveToolOutput, DiagnosticLinkParser,
    │   │                    # WorkspaceContext, ProjectInstructions, ProjectTrust,
    │   │                    # PermissionRules, ToolHooks, PullRequestTools,
    │   │                    # DocumentWriter, SubprocessRunner
    │   ├── MCP/             # Client, routing, effect catalog, tool gate,
    │   │                    # catalog promotion, failure classifier
    │   ├── Integrations/    # Google (Gmail / Calendar)
    │   ├── RAG/             # CodeIndex (BM25 over the workspace)
    │   └── Terminal/ · Voice/ · Watch/ · Vision/ · Updates/
    └── SwiftOpenWork/       # the app
        ├── App/             # Entry, App Intents, window frame persistence,
        │                    # LocalInferenceWiring
        ├── State/           # AppState (the EngineHost), AutomationScheduler,
        │                    # LoopRunner, HeadlessAgentTurn
        └── UI/
            ├── Navigation/  # Sidebar, Spotlight
            ├── Theme/ · Components/
            └── Views/       # Chat, LocalModels, Agents, Automations, Loops,
                             # Editor, Preview, Settings, Inspector (incl. Files
                             # tab), Dashboard, …
```

### Modules

Each folder under `Sources/` is a module, defined once, as a target in `Package.swift`. The Xcode
project links them all as one dynamic library, the package's `SwiftOpenWorkKit` product, so each
third-party package is linked into the app exactly once. A module can only use what a lower module declares `public`, and cannot import anything above it, so the
compiler enforces the layering.

The engine never links MLX either. It reaches the in-process engine through the
`InProcessModelEngine` and `LocalServerLauncher` protocols, looked up in `LocalInferenceRegistry`;
the app registers `NativeMLXService` and `LocalMLXEngine` there at launch. With nothing
registered, the built-in provider fails and says why rather than trying another backend.

The engine never sees `AppState`. What it needs from the running app — settings, the current
provider and model, a toast, revealing the preview — is the `EngineHost` protocol, which
`AppState` conforms to and registers in `EngineHosting.host` when it is created. Engine code must
work when there is no host, as in a test that never creates the app's state.

| Module | Depends on | Language mode |
|---|---|---|
| `SwiftOpenWorkCore` | — | Swift 6 |
| `SwiftOpenWorkStorage` | Core | Swift 6 |
| `SwiftOpenWorkLocalInference` | Core, Storage, MLX, Hugging Face, Transformers | Swift 6 |
| `SwiftOpenWorkEngine` | Core, Storage, Yams, MCP, NIO | Swift 6 |
| `SwiftOpenWork` (app) | all of the above | Swift 6 |

Every module and both test targets compile in the Swift 6 language mode, with concurrency errors
fixed rather than suppressed. `Package.swift` sets it once for the package; `project.yml` sets
`SWIFT_VERSION: "6.0"` for the targets Xcode compiles itself (the app and the two test bundles).

JSON from `JSONSerialization` (`[String: Any]`, `Any`) is not Sendable, and the language-server and
MCP layers pass it in and out of actors. The rules that make that compile:

- A request's parameters and result are `sending`: built fresh by the caller, decoded fresh for
  it. `LSPConnection` hands a response from its reader thread to the waiting task as JSON bytes,
  and the task decodes its own copy.
- Diagnostics a session keeps are stored as JSON bytes (`PublishedDiagnostics`), and each read
  decodes a new copy.
- To send a value that is still in use — one element of an array, or arguments read again
  afterwards — send `JSONCopy.fresh(value)`, a deep copy that shares nothing with the original.
- An API whose closure type is `@MainActor` also writes `@Sendable`. Swift 6 implies it and puts it
  in the symbol name; Swift 5 does not, so code built in the other mode cannot link against it.

### Sidebar destinations

| | Destination |
|:---:|---|
| 💬 | Chat & Sessions (including group chats) |
| 🧊 | Local Models |
| 👥 | AI Agents |
| 🖥️ | Model Providers |
| ⚡ | Automations (Schedules) |
| 🔁 | Loops |
| 👁️ | Watch Folders |
| 📂 | Artifacts & Files |
| 🧠 | Memory & Knowledge |
| 🛠️ | Tools & MCP |
| 📊 | Dashboard & Metrics |
| ⚙️ | Settings |

## Build & run

### Xcode (recommended)

```bash
# Regenerate the project if Sources/ changed
brew install xcodegen   # once
xcodegen generate

open SwiftOpenWork.xcodeproj
```

Select the **SwiftOpenWork** scheme → Build / Run.

> The app target compiles `Sources/SwiftOpenWork` and links the modules through the local package's `SwiftOpenWorkKit` product (see *Modules*).

### Swift Package Manager

SwiftPM has to be pointed at the **Xcode** toolchain. `Scripts/swift.sh` does that per
invocation, so nothing global changes and no password is needed:

```bash
Scripts/swift.sh build
Scripts/swift.sh run SwiftOpenWork
Scripts/swift.sh test           # 1,000+ tests, in two bundles
Scripts/swift.sh test --filter WorkspaceContextTests
```

It takes the same arguments as `swift`. `source Scripts/swift-env.sh` does the same for a whole
shell, for the commands below that call `swift` and `xcrun` directly.

What it is working around: if `xcode-select -p` reports
`/Library/Developer/CommandLineTools`, the Command Line Tools toolchain is used instead and the
build dies early with `unknown argument: '-target-arch-variant'` — misleading, because nothing
is wrong with the package.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build
swift run SwiftOpenWork
swift test                      # 1,000+ tests, in two bundles

# Engine tests alone. This builds neither MLX nor the SwiftUI app:
swift build --product SwiftOpenWorkEngineTests
xcrun xctest .build/out/Products/Debug/SwiftOpenWorkEngineTests.xctest
```

(`swift test` itself always builds every test bundle, and `--skip-build` needs all of them to
exist, so run the engine bundle with `xctest` directly.)

`SwiftOpenWorkEngineTests` holds the tests that need only Core, Storage and Engine.
`SwiftOpenWorkTests` holds the ones that need the app, its views, or the MLX engine. Put a new
test in the engine target when it can live there.

`GroupChatEndToEndTests` runs the real agent loop through group turns against a local
OpenAI-style server that records what each agent was sent, and is skipped unless it is told where
that server is:

```bash
python3 Scripts/fake_group_llm.py 18765 /tmp/group.log &
TEST_RUNNER_GROUP_FAKE_URL=http://127.0.0.1:18765/v1 TEST_RUNNER_GROUP_FAKE_LOG=/tmp/group.log \
  xcodebuild test -project SwiftOpenWork.xcodeproj -scheme SwiftOpenWorkEngineTests \
  -destination 'platform=macOS' -only-testing:SwiftOpenWorkEngineTests/GroupChatEndToEndTests
```

Tests never touch your real data: under XCTest the app stores settings and sessions in a
temporary folder per test process (set `SWIFTOPENWORK_DATA_DIRECTORY` to point a deliberate run
at real data). The language-server integration tests use whichever servers are installed and
skip the rest: the TypeScript, pyright, rust-analyzer and gopls tests run only when those servers are on `PATH`, and the in-process MLX shutdown tests only where their model is installed.

`DEVELOPER_DIR` alone is not always enough, which is the other half of what `Scripts/swift.sh`
handles. If `swift` on your `PATH` is a standalone toolchain — swiftly puts one in
`~/.swiftly/bin`, and `swift --version` will say `swift-6.3-RELEASE` rather than naming a
`swiftlang` build — it will be used against Xcode's SDK and crash in the frontend parsing
`Accelerate.swiftmodule` (`type 'Quadrature.Error' does not conform to protocol 'Error'`).
The wrapper puts the selected toolchain's own `bin` first; by hand that is:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test
```

To fix it for good rather than per-shell (needs your password):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

> If a build fails with `unable to spawn process '.../Metal.xctoolchain/usr/bin/metal'` while
> `xcrun -f metal` resolves fine, the Metal toolchain is a cryptex whose mount path changes on
> reboot and XCBuild has cached the old one. Clear `.build/out/Intermediates.noindex/XCBuildData`.

### Install a Debug build (optional)

The product is **`SwiftOpenWork.app`** (bundle ID `io.github.foscoe63.SwiftOpenWork`); the Swift
module and scheme are `SwiftOpenWork`.

```bash
# After a successful Debug build:
cp -R ~/Library/Developer/Xcode/DerivedData/SwiftOpenWork-*/Build/Products/Debug/SwiftOpenWork.app \
  /Applications/SwiftOpenWork.app
```

Quit any running SwiftOpenWork instance before replacing the bundle.

### Notarizing a release

`Scripts/notarize-release.sh` builds Release, signs nested code and then the app with a Developer ID
Application certificate and hardened runtime, submits to `notarytool`, staples the ticket, checks it
with `spctl`, and zips **after** stapling to `build/release/SwiftOpenWork.zip`. A build that is not
notarised is blocked by Gatekeeper on first launch.

It needs the Developer ID identity and notarisation credentials, in either of two forms:

```bash
# Once: store an Apple ID and app-specific password in the keychain
xcrun notarytool store-credentials swiftopenwork --apple-id you@example.com --team-id TEAMID

# Each release
DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=swiftopenwork \
  Scripts/notarize-release.sh
```

or an App Store Connect API key via `APPLE_API_KEY_ID`, `APPLE_API_ISSUER` and
`APPLE_API_KEY_PATH` instead of `NOTARY_PROFILE`. The script stops, rather than half-signing, if
anything it needs is missing. `SIGN_ONLY=1` runs everything up to submission, to check signing
without submitting.
