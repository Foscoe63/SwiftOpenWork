# Evals

A small, fixed set of coding tasks, run through the real agent loop and scored by a command — so a
change to a prompt, the tool-repair layer or sampling can be judged by a pass rate.

```
Evals/tasks/<id>/task.json   id, title, prompt, verify (shell, exit 0 = done), timeout_seconds, tags
Evals/tasks/<id>/files/      the workspace the agent starts in (committed to a throwaway git repo)
```

Run against any OpenAI-compatible endpoint — including this app's own *Local Model API* (Settings):

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build --product SwiftOpenWorkEngineTests
SWIFTOPENWORK_EVAL_URL=http://127.0.0.1:11500/v1 \
SWIFTOPENWORK_EVAL_KEY=<local api key> \
SWIFTOPENWORK_EVAL_MODEL=<model id> \
SWIFTOPENWORK_EVAL_OUT=/tmp/eval-after.json \
SWIFTOPENWORK_EVAL_BASELINE=/tmp/eval-before.json \
TEST_RUNNER_SWIFTOPENWORK_EVAL_URL=... \
xcrun xctest -XCTest EvalHarnessTests/testRunAgainstARealModel .build/out/Products/Debug/SwiftOpenWorkEngineTests.xctest
```

(`xctest` reads the variables directly; the `TEST_RUNNER_` prefix is for `xcodebuild test`.)
`SWIFTOPENWORK_EVAL_ONLY=fix-off-by-one,edit-config` runs a subset. The report is JSON; with a
baseline it also prints which tasks regressed and which were fixed.

Adding a task: make a folder, write `task.json` and `files/`. `EvalHarnessTests` fails if a task's
verifier already passes before the agent does anything, since that task would measure nothing.
