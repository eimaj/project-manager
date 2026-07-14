# Architecture

This document describes what `/pm-generate` and `install.sh` put on disk, and how the
generated skills coordinate across sessions.

## Two source-of-truth boundaries

```
<repo>/                       # the package (cloned, source of truth for templates + lib)
  install.sh                  # symlinks pm-generate, installs lib, inits state, seeds config
  lib/                        # tool-agnostic bash, installed (copied) into the framework dir
  templates/pm-*/SKILL.md     # placeholder skills, RENDERED by pm-generate
  skills/pm-generate/         # the generator skill itself (symlinked by install.sh)
```

```
~/.claude/skills/
  pm-generate -> <repo>/skills/pm-generate   # SYMLINK (logTool-style; tracks the repo)
  pm-init/SKILL.md                           # RENDERED real file (your framework paths baked in)
  pm-start/SKILL.md                          # RENDERED
  pm-status/SKILL.md                         # RENDERED
  pm-end/SKILL.md                            # RENDERED

~/.claude/pm/                 # framework dir (lib + runtime state ONLY — no skills here)
  lib/session.sh              # resolve a stable per-session id
  lib/scaffold.sh             # scaffold a new project's files; upsert the registry
  lib/handoff-write.sh        # atomic per-session LAST-SESSION.md block update
  lib/config.sh               # read ~/.config/pm/config.json, expose generic tool accessors
  registry.jsonl              # the project list (append-only, deduped by root) — gitignored state
  sessions/<session-id>       # per-session marker → active project root — gitignored state

~/.config/pm/config.json      # personal named-tool registry + paths — gitignored
```

## The personal config (schema v2)

`~/.config/pm/config.json` is a **named-tool registry**, not a fixed slot map:

```json
{
  "version": "2.0",
  "paths": { "framework_root": "~/.claude/pm", "notes_root": "<abs notes root>" },
  "tools": {
    "<name>": { "provider": "<backend|none>", "root": "<abs path?>", "skills": ["…"] }
  }
}
```

`lib/config.sh` **exposes generic accessors over the tools map** — `pm_tools`,
`pm_tool_defined`, `pm_tool_provider`, `pm_tool_root`, `pm_tool_skills`,
`pm_tool_root_or_notes` — rather than exporting a `PM_*` variable per role.
`pm_load_config` validates the config and exports only the fixed framework paths
(`PM_FRAMEWORK_ROOT`, `PM_NOTES_ROOT`, `PM_REGISTRY`, `PM_SESSIONS_DIR`,
`PM_CONFIG_RESOLVED`). See [SLOTS.md](SLOTS.md) for the full accessor API and degrade
contract.

### Why generated skills are rendered, not symlinked

`pm-generate` produces **user-specific** output — your framework paths (`framework_root`,
`notes_root`) are substituted into the skill text (tool identity stays in the config; the
render is near-static). Symlinking a single shared copy would be wrong: two users want
different content. So the generated `pm-init/start/
status/end` are written as **real files directly into `~/.claude/skills/pm-*`**, with a
declinable guard that refuses to overwrite a skill it did not itself render (it greps for a
`Rendered by /pm-generate` marker). Only the generator skill (`pm-generate`), which is
identical for everyone, is symlinked — exactly the logTool convention.

## Project identity & the registry

- **Project identity = its folder root path.** No IDs; the folder is self-describing.
- The **registry** (`~/.claude/pm/registry.jsonl`) is append-only and **deduped by `root`**:
  re-initializing a project updates its line in place rather than adding a duplicate.
- Each registry line records `{name, root, tool_refs, created}`. `tool_refs` is a map keyed by
  the tool names your config defines — `tool_refs.<name>` is how *this* project is identified
  inside that tool's backend (a Granola folder for `meetings`, a Linear project id for `tasks`,
  a todoApp tag for `todo`, …). Its meaning is resolved against the tool at runtime, so the
  registry stays tool-agnostic; a tool with no entry falls back to keyword matching.

## Per-session markers (concurrency)

- `pm-start` resolves a stable session id via `lib/session.sh` and writes
  `~/.claude/pm/sessions/<id>` containing the active project root.
- `pm-status` and `pm-end` **read** that marker (they never write it) to know which project
  is active in *this* session.
- Two sessions can work two different projects at once; each holds its own marker.

## Per-project files (in `<project-root>`)

| File | Written by | Purpose |
|---|---|---|
| `.pm/config.json` | `pm-init` (always rewritten) | canonical per-project config (`name`, `root`, `tool_refs`, team, keywords, collaborators, auto_ship, session_color); MAY also carry an optional `tools{}` **override** block (see below) |
| `CONTEXT.md` | `pm-init` (seed; never clobbered) | stable hand-edited overview |
| `CALENDAR.md` | `pm-init` seed; `pm-start` regenerates Synced section | forward-looking dates; manual entries below the `<!-- PM:MANUAL -->` marker are preserved |
| `meetings.jsonl` | `pm-start` appends pointers | `{meeting_id, date, title, path}` pointers into the meeting archive — never transcript copies |
| `reports/` | `pm-init` (seed dir; never clobbered) | this project's OWN report artifacts — distinct from a tool's global `root` (the shared, cross-project sink). See [SLOTS.md](SLOTS.md#per-project-reports-rootreports) |
| `LAST-SESSION.md` | `pm-end` (per-session block via `handoff-write.sh`) | forward handoff; one block per session, never clobbered across sessions |

### Per-project tool override

A project's `.pm/config.json` may carry an optional `tools{}` block that overrides the global
registry **for that project only**. After `pm_load_project <root>`, the `config.sh` accessors
resolve the **effective** tool = project override ?? global (per field): precedence is
`project override > global > undefined (degrade)`. The override is **read-only** w.r.t. the global
`~/.config/pm/config.json` (never written back) and is scoped to the current shell, so projects
never leak into one another. A hand-added `tools{}` block survives re-init verbatim (the
scaffold's deep-merge preserves it, like any unknown field). See
[SLOTS.md](SLOTS.md#two-levels-global-registry--per-project-override) for the full contract.

`scaffold.sh` generates these per-project files **inline** (heredocs + `jq`), not from a
template directory — the seeds are conditional (team lists, pointer detection, per-tool ref
links), so a single inline generator is the one source of truth rather than a parallel skeleton set.

## Handoff write (no lost updates)

`handoff-write.sh` replaces **only the calling session's block** in `LAST-SESSION.md`,
preserving every other session's block, under an atomic `mkdir`-based lock. A pre-existing
marker-less file is wrapped once as a `legacy` block so old content survives the first write.

## Install vs. generate (who does what)

- **`install.sh`** (run once after clone): symlinks `pm-generate`, copies `lib/` into the
  framework dir, creates an empty `registry.jsonl` + `sessions/`, and seeds
  `~/.config/pm/config.json` from the template if absent. Idempotent.
- **`/pm-generate`** (run in Claude Code): audits your tools + skills, groups them, and walks
  you through naming each tool; writes the real `config.json`, (re-)installs `lib/`, and renders
  the four `pm-*` skills. Re-runnable to change your tool registry.
