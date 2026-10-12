# SwiftOpenWork — competitive deep dive (2026-10-12)

Method: read the README and source tree (about 70k lines, 230 Swift files), then compared against
the products below. Competitor facts come from their own GitHub/docs pages where I could fetch
them, otherwise from third-party write-ups (marked †). "Not found" under SwiftOpenWork means a
keyword search of `Sources/` came back empty. It is not proof of absence, so confirm before building.

## Who is who

| You said | What it turned out to be |
|---|---|
| OpenCode | sst/opencode — MIT, TypeScript/Bun, client/server agent harness, ~135k stars† |
| CoWork | Claude Cowork — Anthropic's desktop agent tab (folders, plugins, scheduled tasks, Dispatch)† |
| Bionic | **LM Studio Bionic** — closed-source desktop agent for code *and* documents/slides/PDFs on local or open models |
| Nativ | MIT SwiftUI app (macOS 26+) that runs MLX models and serves them as an OpenAI- and Anthropic-compatible local API. It is a model host, not an agent |
| Radiance | Almost certainly **Radiant** (templetongroup/radiant, MIT, Electron). Your README already says "Radiant-class" |
| Others worth studying | Codex app, Claude Code, Cline, Goose, Zed (ACP), Conductor / Emdash / Superset / Vibe Kanban, Agent! (macOS26), G-Rump, Maestri |

## Where SwiftOpenWork already leads

Don't copy anything here. These are real advantages over most of the field:

- In-process MLX engine with KV-cache reuse, shared scheduling of one model, and honest speed/context numbers. Nobody else in the list has this inside the agent app.
- Real language servers (sourcekit-lsp, clangd, tsc, pyright, rust-analyzer, gopls) with fail-closed rules ("no root, no answer", never a partial index) and error feedback attached to each edit.
- Seatbelt OS-level sandbox, sub-agent isolation, fail-closed MCP read/write classification.
- Per-turn on-disk checkpoints with "restore files to before this turn", conversation forks, session-scoped undo.
- Tool-call repair layer for weak local models; no sampling penalties on tool turns.
- Self-verifying Loops, five automation triggers, missed-run catch-up, cron.
- Live preview with element picker, console capture, `preview_check`.
- Group chats with handoffs. Prompt caching. Shortcuts/Siri App Intents.

## Gaps, ranked by value for the effort

### Tier 1 — high value, fits the architecture

**1. Lifecycle hooks (Claude Code, OpenCode plugins)** — not found in code.
Deterministic shell commands on `PreToolUse`, `PostToolUse`, `SessionStart`, `Stop` and `UserPromptSubmit`,
configured in `.swiftopenwork/hooks.json`. A hook can block a call, rewrite its input, or add context.
This is how power users enforce "always run the formatter" or "never touch `migrations/`". Skills and
rules can't do it because the model may ignore them. All tool execution already goes through
`ToolExecutionEngine`, so the hook point is single and well defined. `AIMemoryHooks.swift` is a
narrow precedent.

**2. Rule-based permissions (OpenCode)** — current model is four levels (Ask/Safe/Allow/Allow All).
OpenCode resolves allow/deny/ask by glob per tool, with session rules overriding agent rules overriding
global config, and persists approvals. Add: "Always allow `git status*`" on the approval card,
a `permissions` block per agent and per project, and deny rules (`rm -rf *`, `.env`). It layers on
`ToolApprovalManager` and keeps today's levels as the default preset.

**3. Pull request and CI loop (Radiant, Codex app, Conductor)** — not found (only prose mentions).
Commit, push and open a PR from the app. Show branch PR + CI status above the composer. Let the user
leave **inline comments on a diff** that the agent then addresses (Codex's review pane). You already
have the diff views and worktrees, so this is mostly `gh` plumbing plus a comment-to-prompt path.
"CI failed → Ask Agent to Fix" mirrors your existing console-error button.

**4. Mid-turn steering + message queue (Radiant)** — not found.
Typing during a turn queues the message. **Steer** interrupts at the next step and sends it, while
**Stop** keeps the partial output. Local-model turns are long, so this matters more for you than for cloud tools.

**5. Read-before-edit gate (Agent!)** — not found.
Refuse `edit_file`/`file_write` on a file the agent hasn't read this turn or that changed on disk since
(hash check). It prevents the classic failure of weak models editing from memory. Your whitespace-tolerant
`edit_file` softens misses but doesn't stop edits against stale content.

**6. Spend budget in dollars and per-step cost (Radiant)** — `KnownModels` has a USD-per-million
table, but I found no dollar budget. You have a token budget. Add a cost budget, cost per turn in the
UI, and automatic stopping of repeated identical failing commands (Radiant does this for long builds).

### Tier 2 — strategic, larger

**7. Agent Client Protocol (Zed, Goose).** ACP lets a host app run Claude Code, Codex, Gemini CLI and others
as agents. Becoming an **ACP client** would make SwiftOpenWork a native Mac front end for the agents people
already pay for, with your checkpoints, review UI, sandbox and preview around them. The reverse (an ACP
*server*) would let Zed or other editors use your local MLX agent. Not found in code. Biggest reach gain;
needs a spec spike first.

**8. Local OpenAI/Anthropic-compatible server (Nativ).** Expose the resident MLX model on 127.0.0.1
(`/v1/chat/completions`, `/v1/messages`) so Claude Code, Codex, OpenCode and Cursor can use it. Nativ
exists to do exactly this, and you already own the better engine. `swift-nio` is declared in
`Package.swift` but I found no server code using it. Bind loopback only, with a token.

**9. Task board over parallel agents (Radiant, Vibe Kanban, Emdash, Superset).** *Deferred (decided 2026-10-12).*
`agent_spawn` + worktrees already do the hard part. Add a Queued / Working / Needs-you / Review / Done
board where each card is a worktree run, plus optional import of GitHub Issues or Linear tickets
(Emdash). "Needs you" is the key idea: the agent parks at a decision instead of guessing.

**10. Per-message model routing and provider fallback (Radiant "Jev", Agent!).** Send easy turns to a small fast
model and hard ones to the big one. On 429/timeout, fall through an ordered provider list. Not found.
Fits your local-first story: small local model by default, escalate on failure.

**11. Subscription sign-in (Radiant, Goose via ACP).** Use a Claude, ChatGPT or Copilot login instead of an
API key. Check each vendor's terms before building; this is the riskiest item on the list.

### Tier 3 — polish and nice-to-have

12. **Spotlight indexing of conversations** (G-Rump) — `CSSearchableItem` not found. Small, very native.
13. **User-defined tools** (OpenCode `.opencode/tools/`) — a JSON-schema + shell command file that becomes a first-class tool without writing an MCP server.
14. **Recipes** (Goose) — export/import Loops and Automations as parameterised, shareable files. Exports exist; parameters and import don't, as far as I saw.
15. **Computer control, not just perception.** You have `screenshot_window` and `accessibility_tree` (read-only). Agent! drives apps through 25 Accessibility actions, AppleScript/JXA and scripting bridges. Adding click/type/press via AX behind approvals would close the gap with Bionic/Cowork "computer control".
16. **Documents as a first-class output** (Bionic, Cowork): slides, PDFs, spreadsheets, with every change saved. You can read documents (`document_extract`) but I saw no generation tools. This is the "Cowork" half of the market.
17. **Browser bridge into the user's signed-in Chrome** (Radiant). Larger and mostly covered by MCP browser servers; low priority.
18. **Themes** (Radiant: 14 presets, OKLCH-derived custom colours) and **voice with live models**. You have voice already; check whether it's push-to-talk only.
19. **Edit-prediction depth** (Zed Zeta): you have ghost text from the idle local model. Multi-line next-edit prediction is the next step, not a gap.
20. **Plugins as a bundle** (Claude Code/Cowork): skills + MCP + commands + sub-agents in one installable folder. Do this after hooks, since hooks are a component of it.

## Suggested order

1. Hooks → rule-based permissions → read-before-edit gate. These are small-to-medium, share the same chokepoint, and add safety and control.
2. Steering queue, then PR/CI + inline diff comments.
3. Local compatible API server (cheap, high visibility), then ACP client.
4. Task board, model routing, dollar budget.

## Caveats

- Several competitors are moving fast. Roo Code is reported archived, Vibe Kanban's cloud was announced shut down, and Crystal was deprecated (all †). Don't build on those.
- I couldn't fetch Conductor/Emdash/Superset detail pages (rate limited), so those entries rest on a comparison blog.
- I did not run SwiftOpenWork. "Already has it" is from the README plus code searches.

---

# Addendum — holaOS, CoWork-OS, AionUi, Apache Maka

All four are Electron/TypeScript. None is native, which is your standing advantage. Facts below are
from each repo's README. Counts and test numbers are the projects' own claims.

| Project | License | What it is |
|---|---|---|
| holaOS | modified Apache-2.0 | "Agentic workspace" assembled from apps, skills, MCP, memory; Claude Code and Codex run inside it |
| CoWork-OS | MIT | Local "agentic OS": 17 messaging channels, memory in git, 151 skills, automation studio, sandbox profiles |
| AionUi | Apache-2.0 | Hub for 20+ CLI agents over ACP, leader/teammate team mode, WebUI remote access, cron bound to conversations |
| Apache Maka | Apache-2.0 | Harness whose whole runtime is an append-only event log, with a published benchmark/eval framework |

## Best ideas worth taking

**A. Append-only event log as the source of truth (Maka).** Messages, tool calls, permission decisions
and terminations are recorded as events. The UI, the next prompt and crash recovery are all projections
of that log; old tool output drops out of prompts but stays in the log. SwiftOpenWork already has
compaction and per-turn checkpoints, so the cheap version is a per-session audit/event log (what ran, what
was approved, why a turn ended) with **interrupted-turn resume** after a crash or quit. This also gives a
real audit trail for headless runs.

**B. Eval harness (Maka).** Run a fixed task set against a model/config with a verifier and publish
per-task results. You change the prompt, repair layer and sampling often, and local-model quality is your
selling point. A small `Scripts/eval` that replays tasks with test-based verifiers would tell you whether a
change helped. It is the best defense against regressions in the tool-repair layer.

**C. Remote access / WebUI (AionUi, Radiant, CoWork-OS).** *Deferred (decided 2026-10-12); the local API server shipped without the remote/WebUI half.* A loopback-first HTTP+WebSocket server with a token
or QR login, so the phone or another Mac can drive the agent. Pairs with the local-API item (#8 above); the
`swift-nio` dependency is already in `Package.swift`. Messaging-channel control (Telegram, Slack, iMessage;
CoWork-OS has 17, AionUi has 4, Agent! has iMessage) is the same plumbing with an allowlist. Treat as
high-risk: every channel needs sender allowlists, rate limits and refused-not-awaited approvals, which you
already do for headless runs.

**D. Team mode with a shared task board and mailbox (AionUi, CoWork-OS).** *Deferred, including Side Chat (decided 2026-10-12).* Leader splits work, teammates claim
tasks, silent agents are flagged failed and removable. You have group chats and `agent_spawn`; the missing
piece is the **shared board + mailbox** between agents (extends item #9). Add **Side Chat** (CoWork-OS):
ask read-only questions about a running task without interrupting it.

**E. Memory as plain markdown in a git repo, plus "dreaming" (CoWork-OS, holaOS).** Memory you can read and
edit, every change committed, nightly dedupe/prune that queues changes for review, untrusted-source notes
quarantined in a review inbox, secrets redacted at write time. You depend on ai-memory and Hindsight
(external), so a built-in, inspectable store would remove a dependency and fit your privacy stance.

**F. Safety hygiene.**
- Import scanning and quarantine for skills, plugins and MCP servers installed from a URL (CoWork-OS). You read
  `.claude/skills` from any checkout, so a cloned repo can inject instructions. Show an "untrusted project
  skills/rules" prompt before first use.
- Named **access profiles** (Ask / Approve for me / Full access / Custom) bundling sandbox + approval +
  network + filesystem (CoWork-OS). Your Safe/Allow levels are close; this is the rule-based permissions item (#2).
- Tool-call **cluster-failure detection** (Maka, CoWork-OS Mission Control): stop repeating the same failing command.

**G. Cowork-style non-code work (holaOS, AionUi, CoWork-OS, Bionic).** All of them generate real
.xlsx/.pptx/.docx files, preview them live, and ship role assistants (PPT, Word, Excel, dashboard).
This is now table stakes for the "Cowork" category. You have `document_extract` for reading only. Native
route: write OOXML via a small Swift writer or shell out to a bundled tool, with the preview shown through
QuickLook/PDFKit. Also image generation (AionUi, holaOS, CoWork-OS), which you lack.

**H. Cron bound to a conversation (AionUi).** A schedule that either continues an existing chat (keeping
context) or opens a fresh one each run, with per-task model, workspace and reasoning effort, **keep-awake**
while tasks are armed, and the agent able to create schedules itself mid-chat. Your Automations run as fresh
headless sessions; "continue this conversation" and agent-created schedules are the gaps. The app has a
`request_keep_awake`-style need: confirm whether you already prevent sleep for armed schedules.

**I. Recipes / combos marketplace (holaOS HolaHub, CoWork-OS plugin packs, Goose).** Share a full setup
(model, prompt, skills, MCP, schedule) as one file, with the underlying prompt visible. This is the
shareable-recipes item (#14) plus plugin bundles (#20); two more projects converged on it.

**J. Mixture of Agents (CoWork-OS).** Advisor models draft, an aggregator model writes the final answer.
Cheap to try with your group-chat plumbing, and plausible for squeezing quality from several small local models.

**K. ACP confirmation.** AionUi (20+ agents) and CoWork-OS (external ACP/A2A delegation) both ship ACP, on top of
Zed and Goose. Four independent projects now treat it as the integration standard, so ACP client (#7) moves
up to the top of Tier 2.

## Not worth copying
- Electron-era features that your native stack already beats (xterm.js terminals, Chromium browser panes).
- Bundled "free frontier model" access (holaOS) and enterprise SSO tiers: business models, not features.
- Hosting 150+ prebuilt skills for breadth. Maintenance cost is high; ship a few and an importer instead.
- Maka's "peer mesh" and Windows-sandbox work: experimental and off your platform.

## Revised priority

Status as of 2026-10-12: items 1–5 and 7 are built (PR #49) except the pieces marked deferred below; the task board, remote access and Side Chat are deferred by choice.

1. Hooks, rule-based permissions, read-before-edit gate (unchanged).
2. Event/audit log with interrupted-turn resume (new, builds on checkpoints).
3. Steering queue; PR/CI + inline diff comments.
4. Local API server (done); token-authenticated remote access (deferred); ACP client (done).
5. Eval harness (new, cheap, protects everything else).
6. Conversation-bound schedules (done). Shared task board + mailbox and Side Chat: deferred.
7. Untrusted skills/rules prompt; built-in markdown memory; document and image generation.
