<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="112" alt="SwiftOpenWork icon" />
</p>

<h1 align="center">SwiftOpenWork</h1>

<p align="center">
  <strong>Native macOS autonomous AI workbench</strong><br/>
  Swift · SwiftUI · Apple Silicon — no Electron
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple&logoColor=white" />
  <img alt="Swift 5.9 language mode" src="https://img.shields.io/badge/Swift-5.9%20language%20mode-F05138?style=flat-square&logo=swift&logoColor=white" />
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-MLX-5AC8FA?style=flat-square&logo=apple&logoColor=white" />
  <img alt="MCP" src="https://img.shields.io/badge/MCP-Swift%20SDK-412991?style=flat-square" />
  <img alt="License MIT" src="https://img.shields.io/badge/License-MIT-green?style=flat-square" />
</p>

<p align="center">
  <a href="#-features">Features</a> ·
  <a href="#-mcp-servers">MCP</a> ·
  <a href="#-architecture">Architecture</a> ·
  <a href="#-requirements">Requirements</a> ·
  <a href="#-build--run">Build</a> ·
  <a href="#-configuration">Config</a> ·
  <a href="#-privacy">Privacy</a>
</p>

---

## Overview

**SwiftOpenWork** is a standalone native macOS app for autonomous agents, multi-agent collaboration, scheduled automations, and local/cloud LLM orchestration.

It ships as a real `.app` — UI and tooling sit on system frameworks (`Accelerate`, `Vision`, `PDFKit`, `WebKit`, `Speech`, Keychain). End users who install a build do **not** need Xcode or Swift installed.

Agent tooling aims for **Radiant-class** reliability: official MCP Swift SDK sessions, namespaced first-class MCP tools, native function calling on local MLX and cloud providers, and a multi-turn tool loop that keeps going until the job is done (with sensible guards for local models).

---

## Download

Get **`SwiftOpenWork.zip`** from the [latest release](https://github.com/Foscoe63/SwiftOpenWork/releases/latest), unzip it, and drag `SwiftOpenWork.app` to Applications. Releases are signed with a Developer ID and **notarised by Apple**, so the app opens with no Gatekeeper warning. The app checks for new releases itself.

Needs macOS 14 or later; Apple Silicon for the built-in local models. Accessibility and Screen Recording are only requested the first time the agent uses a tool that looks at the screen. Since those permissions follow the code signature, you grant them once, not on every update.

---

## Features

### Autonomous agents

| | Capability |
|:---:|---|
| 🔁 | Multi-turn ReAct with **native tool / function calling** (OpenAI, Ollama, in-process MLX) plus markdown / XML fallbacks |
| 📁 | Filesystem — `file_read` (paginated, numbered), `file_write`, `edit_file`, `multi_edit` (several edits, all or nothing), `file_list`, `file_copy`, `file_move`, `file_delete` |
| 🔎 | Code search — `grep` (regex → `path:line: text`), `glob` (`**/*.swift`), `find_symbol` (declarations only), `search_workspace` (BM25 index) |
| 🧠 | **Code intelligence** (language servers) — `go_to_definition`, `find_references`, `symbol_info` (type, signature, docs), `code_diagnostics` (errors for one file in seconds), `document_symbols` (outline), `call_hierarchy` (callers / callees). Answers come from the compiler's index, so `find_references` lists uses of *that* declaration, not every word that matches |
| ✏️ | Refactor — `rename_symbol` renames through the language server where one applies (only references to that declaration change) and falls back to whole-word replacement otherwise, saying which ran; `dry_run` shows the hit list first |
| 🔨 | Build & test — `build_project`, `run_tests` — commands are inferred for SwiftPM **and Xcode** projects/workspaces (shared scheme discovery included); failures come back as `file:line: message`, and `run_tests(only_failing: true)` re-runs just the ones that failed |
| 🌿 | Git — `git_status`, `git_diff`, `git_log`. Committing stays yours *on your checkout*; the agent may commit only inside a worktree of its own, where history is additive and cannot rewrite yours |
| ↩️ | Undo — `changed_files`, `revert_changes` restore everything a turn touched |
| 💻 | Shell — `terminal_command` / `run_command` |
| 🌐 | Network — `fetch_url`, `web_search` |
| 💬 | Interaction — `ask_user`, `exit_plan_mode`, `todo_write` |
| 👁️ | **Perception** — `screenshot_window` (see any running app's window), `accessibility_tree` (read it as text — cheap, and works with text-only models), `run_app` (launch it and report what happened) |
| 🌍 | **Live preview** — `preview_start` (detect and run the dev server, or serve a static site), `preview_check` (reload and report console errors, failed requests, visible text and a screenshot — for any preview tab), `preview_logs`, `preview_stop` |
| 🌿 | Isolation — `worktree_create`, `worktree_list`, `worktree_remove`, `git_commit` (confined to agent worktrees) |
| 🧮 | Utilities — `calculator`, `get_current_date`, `document_extract` |
| 📧 | Optional Google — `gmail_*`, `google_calendar_*` |

- Full JSON parameter schemas via `ToolSchemaCatalog` (critical for local-model tool use)
- **Workspace context** in the system prompt — path, project type, layout, git branch and dirty count
- **Per-repo instructions** — `SWIFTOPENWORK.md` / `AGENTS.md` / `CLAUDE.md` at the workspace root (`OPENWORK.md` from 1.1 is still read)
- **Inline diffs on the tool card** — an edit shows `+N/−N` where it claims to have edited something, and the changed lines with context when you expand it. Stored with the transcript, so it is still there after a relaunch
- **Turn-change review** — a footer appears when a turn touched files; per-file diffs (side-by-side or unified), revert one or all. A session-wide view lists everything the session touched, with git's diff
- **Restore files to any point in the conversation** — right-click a message → *Restore Files to Before This Turn*. Checkpoints are sealed on disk per turn, survive quit/relaunch, and the sheet names every file it will rewrite or delete before it touches anything. The agent's own `revert_changes` stays scoped to the current turn: a person choosing a point in their own transcript is doing something different from an agent silently rewinding ten turns of work
- **Live command output** — a build or test run streams into the tool card and the terminal panel while it runs, instead of showing nothing until it exits
- **Fork a conversation** from any message — right-click it. The branch is the conversation only: files the discarded turns changed are still on disk, and the fork says which
- Context compaction keeps a factual digest of what dropped turns did (files edited, commands run, failures), so a long session does not forget its own work. It fires at *milestones* — a green test run, a clean tree — as well as on token pressure, so it trades detail for room when history is most disposable
- **Shortcuts & Siri** — "Ask SwiftOpenWork" and "Run Automation" App Intents run the same agent loop. Approvals are refused rather than awaited when nothing is on screen to grant them, and the result reports what it skipped
- **Plan mode** (read-only tools + `exit_plan_mode`)
- Approval gates for destructive / MCP write actions. MCP read/write classification is **fail-closed**: a tool is a read only when a known server advertises it and it is absent from that server's write list, so unknown servers ask. Expect more prompts than a name-prefix heuristic would produce — that is the point
- Sub-agent spawning and inter-agent messaging in the Side Inspector

### Code intelligence

The code-intelligence tools run real language servers, started on first use and kept running per project (stopped after ten idle minutes):

| Language | Server | Project root it needs |
|---|---|---|
| Swift, C, Objective-C (packages) | `sourcekit-lsp` from Xcode | `Package.swift`, `compile_commands.json` or `buildServer.json` |
| Swift / Objective-C (Xcode projects) | `sourcekit-lsp` + [`xcode-build-server`](https://github.com/SolaWing/xcode-build-server) | run `setup_xcode_language_server` once |
| C / C++ | `clangd` | `compile_commands.json`, `compile_flags.txt` or `.clangd` |
| TypeScript / JavaScript | `tsc --lsp` (TypeScript 7+) or `typescript-language-server` (TypeScript 5–6) | `tsconfig.json`, `jsconfig.json` or `package.json` |
| Python | `basedpyright` or `pyright` | `pyproject.toml`, `setup.py`, `requirements.txt`, … |
| Rust / Go | `rust-analyzer` / `gopls` | `Cargo.toml` / `go.mod` |

- **No root, no answer.** Without a project root a server answers from the open file alone, which looks complete. The tools refuse instead, and say what is missing or how to install the server
- **Never a partial index.** Index-backed answers wait for indexing to finish (`workspace/synchronize` for sourcekit-lsp); a timeout is an error, not a short list. The tool card shows indexing progress while it waits
- **Errors come back with the edit** — after `file_write`, `edit_file` or `multi_edit`, a server that is already running for that file adds its verdict to the tool result ("sourcekit-lsp reports 1 error in …", or "no errors"), so a model that skips checking still sees the error it just made. It never starts a server or waits for an index: the check is capped at 4 seconds and reports errors only
- **Kept in step with the disk** — edits from tools, the terminal or another editor reach the server through FSEvents; a crashed server is restarted and the answer says so
- **Xcode projects** — `setup_xcode_language_server` (asks for approval) writes `buildServer.json` and builds the scheme once. xcode-build-server does not index, so answers state how old the last build's index is and which files changed since, and a compiler rename refuses while the index is stale. Keep `buildServer.json` out of git: it holds absolute paths
- Renames check every edit lands on the old name before writing anything, and restore already-written files if a write fails
- Clean chat UX: leaked model thinking moves to **Reasoning**, approvals sit **below** the answer, routine MCP status chips stay out of the way

### Local Apple Silicon (MLX) & providers

- **Local Models** tab (On Device / Catalog) for MLX discovery and selection
- Built-in Apple Silicon path (`NativeMLXService` / `LocalMLXEngine`) with real `ToolSpec` + `streamDetails` tool calls
- **The system prompt is in the context once.** `ChatSession` re-sends its `instructions` on every call, so a reused session used to append the whole system prompt — tool schemas, workspace context — again on every turn and every tool round. Measured on Ornith-1.5-35B, turn two of a chat prefilled 499 tokens to add a six-word message; it now prefills 14
- **Shared fairly** — chat turns, automations, Shortcuts and parallel sub-agents take turns on the one in-process model, first come first served. A queued turn says what it is waiting for, and the chat header names any background run. Two conversations keep their own KV caches, so taking turns does not re-prefill both
- **Honest numbers** — the context meter shows the real window in use for local models (cached prefix included), each reply shows its measured decode speed, and multimodal checkpoints report the context window they actually declare (262k for Ornith and Qwen3.6, not a 131k fallback). Unloading a model now actually frees its memory
- **KV cache reuse** — a continued conversation is appended to the live `ChatSession` rather than re-prefilled. Measured on a 48B model, time-to-first-token goes from 1.5s at three messages and climbing ~0.67s per exchange, to a flat 0.9s. Any rewrite of earlier history (compaction, a fork) rebuilds instead, because a cache describing text no longer in the conversation would keep steering the model invisibly
- Optional servers: oMLX, mlx_lm, Osaurus, Ollama, LM Studio
- Cloud & remote: OpenAI-compatible, Anthropic, Groq, OpenRouter, DeepSeek, Mistral, Gemini, custom endpoints
- Provider probing, model listing, Keychain-backed API keys

### Schedules & automations

- Five triggers, all of which fire: **manual**, **scheduled**, **on app launch**, **on new
  session**, and **on changes in a watched folder**
- Schedules are read by `AutomationSchedule` — `Daily at 6:00 AM`, `Every 30 mins`,
  `Weekly on Monday at 8am`, `Monthly on the 1st`, or a five-field cron expression
  (`0 9 * * 1-5`). A string it cannot honour **never fires and says so on the card**, rather than
  rendering a next-run time nothing will keep
- A run that was missed while the app was closed fires **once** on the next launch, not once per
  slot missed
- Scheduled runs go through the same headless path Shortcuts uses: recorded as a real session you
  can open and audit, and approvals are refused rather than awaited when nobody is watching
- Create / edit / Run Now / History / Export / Pause / Resume / Delete
- Watch folders with filesystem triggers and artifact synthesis

### Editor and live preview

- **Code editor** in the inspector (⇧⌘E) and in Artifacts & Files — tabs, syntax highlighting for 20+ languages (strings and comments are lexed properly, so a `//` inside a string stays a string), line numbers, current-line highlight, find (⌘F), go to line (⌘L), toggle comment (⌘/), indent and outdent (⌘] / ⌘[), auto-indent that opens `{}` pairs, and **Tab completion** from the file's own words, the workspace's declarations and the language's keywords. After a typing pause, **ghost-text** from the idle local model (never queued behind an agent turn, never swapping the resident checkpoint). **⌘-click** a name to jump to its declaration; ⇧⌘O opens any workspace file
- **Inline AI suggestions** — pause typing and the model proposes the rest of the line (or the block it opens) as grey ghost text; ⇥ accepts it as one undo step, esc or moving the cursor dismisses it, and typing what it says keeps the rest. Measured on Ornith-1.5-35B: about 0.8–1.1s per suggestion once the model is loaded. It never waits in line: when an agent turn or automation holds the local model, no suggestion is made. By default it uses your chat model only when that runs on this Mac; a cloud model is used only if you pick one (editor status bar or Settings)
- **Built for an agent editing the same files.** A clean tab follows the agent's writes and says it reloaded. A tab with unsaved edits is never overwritten: a banner offers Compare, Take Disk Version or Keep Mine, and Save refuses until you choose. Line endings (LF/CRLF) and indentation are kept as the file had them. The composer warns when a file has unsaved edits, because the agent reads what is on disk
- **Everything opens where you are** — build and test errors, `+N/−N` diffs on tool cards, and console errors from the preview open the file at the line
- **Live preview** (⇧⌘P) — detects how to run the project (`package.json` dev script with npm/pnpm/yarn/bun, Django, Rails, Hugo, Jekyll, or a static `index.html`, which the app serves itself with no toolchain), starts it with your login shell's PATH so nvm and Homebrew Node are found, waits until it answers, and shows it. Address bar, back/forward, phone/tablet/laptop widths, reload on file change for static sites (dev servers keep their own hot reload)
- **Several previews at once** — up to six tabs, each with its own page, history, console and viewport, shown one at a time, side by side or stacked (Preview menu, ⌥⌘T for a new tab). Starting a second server opens a new tab instead of replacing the first page; Duplicate Tab puts the same page beside itself to compare a phone and a desktop width
- **Console that reaches you** — console output, uncaught exceptions, unhandled rejections, failed `fetch`/XHR requests and missing scripts are captured per page load, with a badge, links from stack traces into the editor, and **Ask Agent to Fix**. The server log sits beside it. Stopping a server stops every process it started, and quitting the app stops them all
- **Point at what you mean** — the cursor button on the preview toolbar highlights whatever is under the pointer. Clicking picks the element instead of pressing it, and puts its selector, text, HTML and a cropped screenshot into the message box for you to say what to change. Esc cancels
- **Screenshot to chat** — the camera button attaches a picture of the page exactly as it looks
- **The agent sees the same page**: `preview_check` reloads, waits for the page to settle and returns what went wrong plus a screenshot, even when the pane is not on screen. Starting a server asks for approval like any shell command; checking a page does not

### Workspace, skills & desktop UX

- **A new chat suggests what fits the workspace** — ideas to build in an empty folder; for a web, Swift or Python project, *explain it*, *run it and check it* (the preview, a build and a screenshot, or a run with tests), *find and fix a bug* and *add tests*
- **Command palette (⌘K)** — every command with its shortcut, workspace files, chats, agents and settings in one fuzzy-ranked list (initials work: `fip` → Find in Project), driven from the keyboard, recently run commands first. `>` narrows to commands, `@` jumps to a declared symbol, `:42` goes to a line in the open file
- **Find in Project (⇧⌘F)** — above the editor: match case, whole word, regex, include/exclude globs; results grouped by file with the match highlighted, and clicking selects it in the editor. Open files are searched as shown, unsaved edits included. Replace All opens each file in the editor with the change unsaved and one undo step, so nothing reaches disk until you save
- Workspace switcher on the chat header (synced with the sidebar), with **Open Existing Project...** to register a folder already on disk — reopening the same checkout switches to the workspace you already have rather than adding a second one — and **Remove Workspace**, which drops it from the app and leaves the folder untouched
- Enabled **Skills** injected into the agent system prompt
- **Project skills** — a repository can carry its own skills in `.swiftopenwork/skills/<name>/SKILL.md`, loaded only while that workspace is active and re-read from disk every turn, so they are edited with the code and reviewed in a pull request. Optional `name` / `description` / `enabled` front matter; Settings -> Skills & MCP lists what the active project carries and creates the folder. `.openwork/skills` and `.claude/skills` are read too
- Extensions, prompt templates, slash commands (`/clear`, `/agent`, `/model`, …)
- Local RAG (Accelerate), PDF/Vision extract, live canvas, diffs, terminal, voice STT/TTS
- **Window state persistence** — frame, sidebar & inspector widths, open/closed inspector, navigation destination, settings tab, last workspace & session survive quit/relaunch
- **Vibe coding loop** — sticky plan todos from `todo_write`, Plan mode chip / `/plan`, queue a follow-up while the agent is still generating (Stop keeps what you typed), live turn-change review, clickable `file:line` diagnostics, and a project Rules editor for `SWIFTOPENWORK.md`
- **Composer input** — `@file` and `@folder` completion, `@path:line` to paste a focused, numbered excerpt around a line, `@path:first-last` for exactly those lines (what **Mention in Chat** sends for an editor selection), and drag-and-drop or paste of files and images straight into the box
- **Start from a template** — a new workspace can start empty or as a static site, a React (Vite) app, a SwiftUI Mac app or a Python script, each with an `AGENTS.md` that tells the agent how to run and check that kind of project. A new or empty folder also gets a `.gitignore`, `git init` and a first commit, so diffs, worktrees and commits work from the start. A folder that already has files is left as it is
- **Commit from the app** — *Changes this session* has **Commit…**: a checkbox per file and an editable message. Only the session's files are committed, and anything else you had staged stays staged. The agent still cannot commit on your checkout
- **Context meter** — the last turn's real prompt-token count against the model's window, shown beside the composer once it passes half full, amber and then red as compaction gets close. The provider's own number, never an estimate
- **Finished-turn notifications** — a chime plus a banner naming the session, only when the app is in the background and only for turns long enough to have walked away from. A turn that *failed* is announced however short it was

---

## MCP servers

SwiftOpenWork speaks the [Model Context Protocol](https://modelcontextprotocol.io) with a Radiant-inspired client that prefers **failing soft** over freezing chat.

| | Behavior |
|:---:|---|
| 🔌 | Official MCP Swift SDK stdio client (`MCPSDKSession`) + hand-rolled pipe fallback |
| 🏷️ | Live tools injected as `mcp__{serverId}__{toolName}` |
| ⚡ | Cache-first discovery; background warm-up — chat is **not** blocked on every `npx` cold start |
| ⏱️ | Real deadlines that kill hung connects (structured cancel alone is not enough) |
| 🧭 | Server/tool routing refuses ambiguity — a name two enabled servers could answer is an error naming both, never a guess |
| 🧱 | Failed calls come back classified, with a recovery hint. Transient failures retry once; a rejected token or protocol mismatch does not |
| 🎚️ | Per-tool switches under each server, so you can enable a server without enabling everything on it |
| 📋 | “What MCP servers are available?” answers from config + live status — **no tool thrash** |
| 🩺 | Settings → Skills & MCP shows connected / error / tool counts; **Test** probes a server |
| 🔒 | Stock servers ship **disabled** — enable only what you trust |
| 🌍 | Remote HTTP MCP with clearer 401 messaging and optional bearer token (`MCP_TOKEN` / headers) |

### Dispatcher servers and catalog promotion

Some servers — [MacUse.app](https://macuse.app) among them — advertise only two meta-tools,
`get_tool_definitions` and `call_tool_by_name`, with the real work hidden behind them. Asking a
model to hand-nest every call through a dispatcher is exactly what local models get wrong.

So the catalog is **promoted**. When a listing comes back, its entries become directly callable
tools with real schemas for the rest of the turn, and the model is told they are available:

```
macuse.get_tool_definitions   →  64 tools harvested, 13 of them mail_*
macuse.mail_list_accounts     →  called directly, not wrapped
```

No sequence is hardcoded and no workflow is special-cased — the model picks the tool. Write
actions still route through the same approval gate as anything else, classified by the *nested*
target rather than the dispatcher's name, because `call_tool_by_name` is a read when it lists
mailboxes and a write when it sends mail.

> Tip: keep MacUse.app installed and grant Accessibility / Automation when you need write tools.
> For mail reads, Mail.app can stay closed if MacUse uses its local DB path.

---

## Architecture

```text
SwiftOpenWork/
├── Package.swift / Package.resolved   # SPM deps
├── project.yml                        # XcodeGen
├── SwiftOpenWork.xcodeproj
├── Resources/                         # App icon & assets
├── Tests/
└── Sources/                 # one folder per module; see "Modules" below
    ├── SwiftOpenWorkCore/   # library, Swift 6 language mode
    │   ├── Models/          # Agent, Workspace, Session, SessionTodo, Settings,
    │   │                    # ProviderSelection, InlineFileDiff, ToolSchemaCatalog
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
    │   ├── Agents/          # AgentRunner, SubAgentExecutor, approvals,
    │   │                    # ContextCompactor, ContextMeter,
    │   │                    # TurnCompletionNotifier
    │   ├── Automations/     # AutomationSchedule, CronExpression
    │   ├── Editor/          # EditorWorkspace, ProjectSearchModel, syntax
    │   │                    # highlighter, ghost-text
    │   ├── Preview/         # DevServerManager, PreviewController, PreviewLauncher,
    │   │                    # StaticFileServer
    │   ├── Providers/       # OpenAI, Anthropic, Ollama, ProviderRouter
    │   ├── LSP/             # LSPConnection (JSON-RPC), LanguageServerCatalog,
    │   │                    # LanguageServerSession/Pool, FileChangeWatcher,
    │   │                    # CodeIntelligence, SemanticRename, XcodeBuildServer
    │   ├── Tools/           # Execution, CodeSearch, GitTools, BuildDiagnostics,
    │   │                    # FileCheckpointStore, SessionCheckpointStore, SymbolRename,
    │   │                    # LiveToolOutput, DiagnosticLinkParser,
    │   │                    # WorkspaceContext, ProjectInstructions
    │   ├── MCP/             # Client, routing, effect catalog, tool gate,
    │   │                    # catalog promotion, failure classifier
    │   ├── Integrations/    # Google (Gmail / Calendar)
    │   ├── RAG/             # CodeIndex (BM25 over the workspace)
    │   └── Terminal/ · Voice/ · Watch/ · Vision/ · Updates/
    └── SwiftOpenWork/       # the app
        ├── App/             # Entry, App Intents, window frame persistence,
        │                    # LocalInferenceWiring
        ├── State/           # AppState (the EngineHost), AutomationScheduler,
        │                    # HeadlessAgentTurn
        └── UI/
            ├── Navigation/  # Sidebar, Spotlight
            ├── Theme/ · Components/
            └── Views/       # Chat, LocalModels, Agents, Automations,
                             # Editor, Preview, Settings, Inspector, Dashboard, …
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
| 💬 | Chat & Sessions |
| 🧊 | Local Models |
| 👥 | AI Agents |
| 🖥️ | Model Providers |
| ⚡ | Automations (Schedules) |
| 👁️ | Watch Folders |
| 📂 | Artifacts & Files |
| 🧠 | Memory & Knowledge |
| 🛠️ | Tools & MCP |
| 📊 | Dashboard & Metrics |
| ⚙️ | Settings |

---

## Requirements

| Use case | Need |
|---|---|
| **Run a built `.app`** | macOS 14+ (Sonoma or later); Apple Silicon recommended for MLX |
| **Build from source** | **Xcode 26.6+ (Swift 6.3)**, macOS 14+ SDK — `mlx-swift` declares `swift-tools-version: 6.3`, so the package graph will not resolve on an older toolchain whatever language mode this project's own modules use |
| **…and its Metal toolchain** | A separate download as of Xcode 26: `xcodebuild -downloadComponent MetalToolchain`. Without it `mlx-swift` fails at `CompileMetalFile` |
| **Optional local servers** | Ollama, LM Studio, oMLX / `mlx-lm`, or Osaurus — only if you use those backends |
| **Optional MacUse MCP** | [MacUse.app](https://macuse.app); Accessibility / Automation for write actions |
| **Optional language servers** | Xcode provides `sourcekit-lsp`. For other languages: `clangd`, TypeScript 7+ (`npm install -D typescript`), `pyright`, `rust-analyzer`, `gopls`. For Xcode projects: `brew install xcode-build-server` |

Swift / Xcode are **not** required on machines that only install and run a prebuilt app.

---

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

SwiftPM has to be pointed at the **Xcode** toolchain. If `xcode-select -p` reports
`/Library/Developer/CommandLineTools`, the Command Line Tools toolchain is used instead and the
build dies early with `unknown argument: '-target-arch-variant'` — misleading, because nothing
is wrong with the package.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build
swift run SwiftOpenWork
swift test                      # 846 tests, in two bundles

# Engine tests alone. This builds neither MLX nor the SwiftUI app:
swift build --product SwiftOpenWorkEngineTests
xcrun xctest .build/out/Products/Debug/SwiftOpenWorkEngineTests.xctest
```

(`swift test` itself always builds every test bundle, and `--skip-build` needs all of them to
exist, so run the engine bundle with `xctest` directly.)

`SwiftOpenWorkEngineTests` holds the tests that need only Core, Storage and Engine.
`SwiftOpenWorkTests` holds the ones that need the app, its views, or the MLX engine. Put a new
test in the engine target when it can live there.

Tests never touch your real data: under XCTest the app stores settings and sessions in a
temporary folder per test process (set `SWIFTOPENWORK_DATA_DIRECTORY` to point a deliberate run
at real data). The language-server integration tests use whichever servers are installed and
skip the rest: the TypeScript, pyright, rust-analyzer and gopls tests run only when those servers are on `PATH`, and the in-process MLX shutdown tests only where their model is installed.

`DEVELOPER_DIR` alone is not always enough. If `swift` on your `PATH` is a standalone toolchain —
swiftly puts one in `~/.swiftly/bin`, and `swift --version` will say `swift-6.3-RELEASE` rather
than naming a `swiftlang` build — it will be used against Xcode's SDK and crash in the frontend
parsing `Accelerate.swiftmodule` (`type 'Quadrature.Error' does not conform to protocol 'Error'`).
Use Xcode's own toolchain end to end:

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

---

## Configuration

| | Area | Where / tip |
|:---:|---|---|
| 🔑 | **Providers** | Settings → AI Providers — cloud keys are held in the macOS Keychain and removed from `providers.json`; local base URLs for Ollama / LM Studio / MLX servers |
| 🧊 | **Local Models** | Local Models tab — pick an on-device MLX model |
| 🔌 | **MCP** | Settings → Skills & MCP — enable servers, **Refresh Status** / **Test**, restore defaults (disabled) |
| 📬 | **Dispatcher MCP servers** | e.g. `use the macuse mcp-server and check the mail on this computer` — the catalog is promoted on first listing |
| 📄 | **Per-repo rules** | Drop `SWIFTOPENWORK.md` or `AGENTS.md` at the workspace root (`OPENWORK.md` from 1.1 is still read) — build commands, house style, what not to touch |
| 🤖 | **Agents & skills** | Per-agent tools; enabled skills land in the system prompt |
| 🧠 | **Code intelligence** | Nothing to configure for Swift packages. Xcode projects: ask the agent to run `setup_xcode_language_server` (needs `brew install xcode-build-server`). Other languages: install the server listed under *Code intelligence* |
| 🎛️ | **Advanced** | Plan Mode, Max Turn Tokens, sub-agent depth, collaboration room |
| 🧠 | **Context** | Settings → Preferences — auto-compaction and the token threshold that triggers it |
| 🎚️ | **GPU budget** | Settings → Apple Silicon MLX — the budget ratio caps MLX's buffer cache *and* decides which models are badged as fitting |
| 🗣️ | **Voice** | Settings → Extensions — dictation and read-aloud each have a switch, plus a picker for the spoken voice |
| 🗓️ | **Schedules** | Automations — a trigger, a schedule (`Daily at 6:00 AM` or `0 9 * * 1-5`), a target agent, and a prompt. The card shows the next real run, or says the schedule will not run |
| 🗂️ | **Workspaces** | Chat header or sidebar — stays synced with the current session |
| 🪟 | **Layout** | Drag splits / move the window — restored automatically next launch |
| ↩️ | **Restore points** | Right-click any message that changed files → *Restore Files to Before This Turn*. Up to 40 turns per session are kept on disk; deleting a session deletes its snapshots |
| 🔔 | **Finish alerts** | Settings → Preferences → Audio Notifications drives both the chime and the banner |

---

## Privacy

**The agent can see what it built.** A screenshot of any running app — not just a browser tab,
because this is a native macOS app — reaches a vision model directly, and
`accessibility_tree` gives the same window as text, which is cheaper and works with a
text-only local model. Screen Recording and Accessibility are asked for only when a
perception tool is first used, and refusing them disables those two tools and nothing else.

SwiftOpenWork is **local-first**. It talks only to LLM endpoints and MCP servers **you** configure. No bundled third-party analytics or telemetry.

**A local turn never silently becomes a cloud one.** When the selected provider runs on this
Mac and is switched off, SwiftOpenWork will substitute another *local* provider — and if there is
none, it stops and says so rather than answering from whatever cloud endpoint happens to be
enabled. This is not hypothetical: provider selection used to fall through to the first enabled
provider in list order, and a cloud provider commonly sits earlier in that list than the
built-in engine. A disabled *cloud* provider still falls back normally; the rule is about not
leaving the machine.

The built-in Apple Silicon provider means **in-process MLX and nothing else**. It never probes
for a local server to answer on its behalf, so a turn you sent to it either ran here or failed
with the reason.

---

## License

MIT © 2026 SwiftOpenWork
