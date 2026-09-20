# Project skills

Skills in this folder are loaded by SwiftOpenWork for **this repository only**, on top of the
global skills in Settings → Skills & MCP. They are read from disk every turn, so an edit here
takes effect on the next message — nothing has to be re-imported.

Layout — one folder per skill:

    .swiftopenwork/skills/
      release-checklist/
        SKILL.md
      migrations/
        SKILL.md

A single `some-skill.md` file at the top level works too.

Each `SKILL.md` may open with YAML front matter:

    ---
    name: Release checklist
    description: The steps this project takes before tagging a release.
    enabled: true
    ---

    1. `swift test` is green on main.
    2. ...

`name` defaults to the folder name and `description` to the first line of the body.
Set `enabled: false` to keep a skill in the repository without loading it.
