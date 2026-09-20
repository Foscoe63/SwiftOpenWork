---
name: Build and test this project
description: Always build and test through Scripts/swift.sh, and what the guard tests check before a change is done.
---

# Build and test

Use the wrapper, not a bare `swift`:

```
Scripts/swift.sh build
Scripts/swift.sh test
Scripts/swift.sh test --filter ProjectSkillsTests
```

It takes the same arguments as `swift` and pins the Xcode toolchain for that one invocation.

A bare `swift build` can fail with `error: unknown argument: '-target-arch-variant'` followed by
a `swift-frontend` crash while compiling a dependency's `Package.swift`. That is not a problem
with this code — it means `swift` on `PATH` came from a standalone toolchain (swiftly, a
downloaded `.xctoolchain`) while `xcode-select -p` still points at
`/Library/Developer/CommandLineTools`, so a newer compiler was handed an older SDK.
`Scripts/swift.sh` resolves both halves: `DEVELOPER_DIR`, and the toolchain's own `bin` ahead of
`PATH`. `source Scripts/swift-env.sh` does the same for a whole shell.

Fixing it globally instead is one command, but it needs an administrator password, so ask the
user to run it rather than running it for them:

```
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Before saying a change is done

- `Scripts/swift.sh build` is clean.
- `Scripts/swift.sh test` is green. The suite includes guard tests that catch what a compiler
  cannot: `HitTestableButtonSweepTests` (a borderless button must be clickable across its whole
  frame, not just where it draws), `NoDeadFeaturesTests` and `NoDeadSettingsTests` (a setting or
  feature nothing reads is a bug), `SandboxContainmentTests` and `ToolSafetyTests`.
- `project.yml` is the source of truth for the Xcode project. After editing it, run
  `xcodegen generate`.
