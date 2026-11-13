# Configuration

Where each setting lives. See the [README](../README.md) for the overview.

| | Area | Where / tip |
|:---:|---|---|
| 🔑 | **Providers** | Settings → AI Providers — cloud keys are held in the macOS Keychain and removed from `providers.json`; local base URLs for Ollama / LM Studio / MLX servers |
| 🧊 | **Local Models** | Local Models tab — pick an on-device MLX model |
| 🔌 | **MCP** | Settings → Skills & MCP — enable servers, **Refresh Status** / **Test**, restore defaults (disabled) |
| 📬 | **Dispatcher MCP servers** | e.g. `use the macuse mcp-server and check the mail on this computer` — the catalog is promoted on first listing |
| 📄 | **Per-repo rules** | Drop `SWIFTOPENWORK.md` or `AGENTS.md` at the workspace root (`OPENWORK.md` from 1.1 is still read) — build commands, house style, what not to touch |
| 🤖 | **Agents & skills** | Per-agent tools; enabled skills land in the system prompt |
| 🧠 | **Code intelligence** | Nothing to configure for Swift packages. Xcode projects: ask the agent to run `setup_xcode_language_server` (needs `brew install xcode-build-server`). Other languages: install the server listed under *Code intelligence* |
| 🎛️ | **Advanced** | Plan Mode, Safety Level, turn token limit (from 100K, or none) and spend limit (or none), shell sandbox, sub-agent depth, collaboration room |
| 🛡️ | **Permission rules & hooks** | Settings → Advanced edits the project's `.swiftopenwork/permissions.json` and `hooks.json`; `~/.swiftopenwork/` holds your own for every project. Trust a project's hooks there before they run |
| 🔌 | **External agents (ACP)** | Settings → Advanced → External Agents — add Claude Code, Codex, Gemini CLI, OpenCode, Goose or any ACP command; each becomes an agent in the composer, with a model picker (and a *Lean* switch for Claude Code) |
| 🌐 | **Local model API** | Settings → Advanced → Local Model API — off by default; copy the key and the `OPENAI_BASE_URL` / `ANTHROPIC_BASE_URL` lines for the tool that should use the loaded model |
| 🧾 | **Audit log** | `audit/<chat>.jsonl` in the app's data folder; *Reveal audit log* in Settings → Advanced opens it |
| 🧪 | **Evals** | `Evals/README.md` — run the coding tasks against any OpenAI-compatible endpoint and compare two runs |
| 🧠 | **Context** | Settings → Preferences — auto-compaction and the token threshold that triggers it |
| 🎚️ | **GPU budget** | Settings → Apple Silicon MLX — the budget ratio caps MLX's buffer cache *and* decides which models are badged as fitting |
| 🗣️ | **Voice** | Settings → Extensions — dictation and read-aloud each have a switch, plus a picker for the spoken voice |
| 🗓️ | **Schedules** | Automations — a trigger, a schedule (`Daily at 6:00 AM` or `0 9 * * 1-5`), a target agent, and a prompt. The card shows the next real run, or says the schedule will not run |
| 🗂️ | **Workspaces** | Chat header or sidebar — stays synced with the current session |
| 🪟 | **Layout** | Drag splits / move the window — restored automatically next launch |
| ↩️ | **Restore points** | Right-click any message that changed files → *Restore Files to Before This Turn*. Up to 40 turns per session are kept on disk; deleting a session deletes its snapshots |
| 🔔 | **Finish alerts** | Settings → Preferences → Audio Notifications drives both the chime and the banner |
