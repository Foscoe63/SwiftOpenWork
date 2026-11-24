# Making a mod

A mod is a folder in `~/.swiftopenwork/mods/<name>/`. **Settings → Mods → New mod…** writes a working one; edit `hooks/register.tsx` and save, and the app reloads it.

Never write into `~/.claude/plugins`, a marketplace folder, or another mod's folder, and never use `claude plugin install`: writing the folder *is* the install. Names are lowercase letters, digits and single dashes, and must not match an existing mod. Keep a mod's saved data in `~/.swiftopenwork/mods-data/<name>/` or use `$.store`.

```
<name>/.claude-plugin/plugin.json   {"name": "<name>", "version": "0.1.0", "description": "..."}
<name>/hooks/hooks.json             {"modules": ["./register.tsx"]}
<name>/hooks/register.tsx           export const register = (on) => { ... }
```

## Hooks

`on('<event>', [matcher], async ($, e, next) => result)`.

| Event | Use |
|---|---|
| `session.start` | Register commands and tools (`$.command.register`, `$.tool.register`). Runs when the mod starts and when the chat changes |
| `prompt.submit` | `return next({ ...e, text })` rewrites a message; `return { drop: 'why' }` takes it |
| `prompt.compose` | `return { sections: [{ text }] }` adds to the system prompt |
| `command.run` | `{ command: 'name' }` matcher; return `{ text }` to answer a slash command |
| `tool.call` | `{ tool: 'Bash' }` matcher (Claude Code's names: Read, Write, Edit, Bash, Grep, Glob, LS, WebFetch). `return { deny: 'why' }` refuses; `const r = await next(e); return { ...r, text }` rewrites the result; or return `{ text }` to answer it yourself. A registered tool arrives as `mcp__<mod>__<tool>` |
| `turn.start` / `turn.step` / `turn.complete` | Observe a turn |
| `ui.render` | `{ component: 'AbovePrompt' }`, `'Pane'`, `'UserMessage'`, `'AssistantMessage'`: return an element tree, or rewrite `e.props` |
| `ui.press` | A press on something the mod drew |

`await next(e)` runs the rest of the chain. Return nothing and the chain goes on. A hook that runs longer than 15 seconds is skipped.

Draw with `const { Box, Text, Button, Input, Select, Link, Code, Markdown } = $.ui.resolve(e)`; open a pane with `$.ui.open({ id, title })`. Sizes are terminal cells (about 8 by 12 points).

## `$`

`$.ui` (toast, status, ask, notify, open, close, copy) · `$.session` (id, cwd, messages, turns, model, usage, send) · `$.prompt` (read, fill) · `$.turn.abort` · `$.model` (complete, fork, classify) · `$.fs` (read, write, list, exists, stat, mkdir, remove) · `$.process.run([argv])` · `$.http.fetch(url, init)` · `$.store` (get, set, delete, keys; per mod) · `$.state` and `atom`, `read`, `update` from `'claude-code'` · `$.clock` (after, every, sleep) · `$.command` · `$.tool` (register, list, call) · `$.mcp.call(server, tool, args)` · `$.agent.list` · `$.audio.speak`.

## Permissions

List what the mod needs in `plugin.json`:

```json
{ "name": "my-mod", "permissions": ["process", "network"] }
```

The choices are `files`, `process`, `network`, `mcp`, `tools`, `model`, `conversation` and `chat`. The person sees exactly that list when they turn the mod on, and any call outside it is refused (and noted in the mod's log). Panels, status text, slash commands and the mod's own store need no permission. A mod that lists nothing at all is not limited, which is how mods made for Claude Code and GrizzyCode keep working; its card is marked "Full access" and the prompt says so. New mods start with only what the starter uses.

## Limits

The code runs in a sandbox: no Node, no `process`, no `require`, no `eval`, and no package imports (only relative files and `'claude-code'`). TypeScript and JSX are fine.

## Sharing

**Export .zip** makes a file anyone can install with **Install from folder or .zip…**. **Publish…** copies the mod into a marketplace folder you choose and adds it to `.claude-plugin/marketplace.json`, then shows the two Claude Code lines to install it. Only publish when asked, into the folder named.
