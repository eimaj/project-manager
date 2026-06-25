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
  pm-generate -> <repo>/skills/pm-generate   # SYMLINK (clog-style; tracks the repo)
  pm-init/SKILL.md                           # RENDERED real file (your slot values baked in)
  pm-start/SKILL.md                          # RENDERED
  pm-status/SKILL.md                         # RENDERED
  pm-end/SKILL.md                            # RENDERED

~/.claude/pm/                 # framework dir (lib + runtime state ONLY — no skills here)
  lib/session.sh              # resolve a stable per-session id
  lib/scaffold.sh             # scaffold a new project's files; upsert the registry
  lib/handoff-write.sh        # atomic per-session LAST-SESSION.md block update
  lib/config.sh               # read ~/.config/pm/config.json, expose slot values (incl. email)
  registry.jsonl              # the project list (append-only, deduped by root) — gitignored state
  sessions/<session-id>       # per-session marker → active project root — gitignored state

~/.config/pm/config.json      # personal slot→tool mapping + paths — gitignored
```

### Why generated skills are rendered, not symlinked

`pm-generate` produces **user-specific** output — your slot values (`meeting_source`,
`tracker`, `logger`, `email`, paths) are substituted into the skill text. Symlinking a single shared
copy would be wrong: two users want different content. So the generated `pm-init/start/
status/end` are written as **real files directly into `~/.claude/skills/pm-*`**, with a
declinable guard that refuses to overwrite a skill it did not itself render (it greps for a
`Rendered by /pm-generate` marker). Only the generator skill (`pm-generate`), which is
identical for everyone, is symlinked — exactly the clog convention.

## Project identity & the registry

- **Project identity = its folder root path.** No IDs; the folder is self-describing.
- The **registry** (`~/.claude/pm/registry.jsonl`) is append-only and **deduped by `root`**:
  re-initializing a project updates its line in place rather than adding a duplicate.
- Each registry line records `{name, root, tracker_ref, meeting_ref, email_ref, notes_ref, created}`.
  Those `*_ref` fields are abstract — what `tracker_ref` or `email_ref` *means* is resolved
  against the `tracker` / `email` slot at runtime, so the registry stays tool-agnostic.

## Per-session markers (concurrency)

- `pm-start` resolves a stable session id via `lib/session.sh` and writes
  `~/.claude/pm/sessions/<id>` containing the active project root.
- `pm-status` and `pm-end` **read** that marker (they never write it) to know which project
  is active in *this* session.
- Two sessions can work two different projects at once; each holds its own marker.

## Per-project files (in `<project-root>`)

| File | Written by | Purpose |
|---|---|---|
| `.pm/config.json` | `pm-init` (always rewritten) | canonical per-project config (`name`, `*_ref` incl. `email_ref`, team, keywords, color) |
| `CONTEXT.md` | `pm-init` (seed; never clobbered) | stable hand-edited overview |
| `CALENDAR.md` | `pm-init` seed; `pm-start` regenerates Synced section | forward-looking dates; manual entries below the `<!-- PM:MANUAL -->` marker are preserved |
| `meetings.jsonl` | `pm-start` appends pointers | `{meeting_id, date, title, path}` pointers into the meeting archive — never transcript copies |
| `LAST-SESSION.md` | `pm-end` (per-session block via `handoff-write.sh`) | forward handoff; one block per session, never clobbered across sessions |

`scaffold.sh` generates these per-project files **inline** (heredocs + `jq`), not from a
template directory — the seeds are conditional (team lists, pointer detection, tracker links),
so a single inline generator is the one source of truth rather than a parallel skeleton set.

## Handoff write (no lost updates)

`handoff-write.sh` replaces **only the calling session's block** in `LAST-SESSION.md`,
preserving every other session's block, under an atomic `mkdir`-based lock. A pre-existing
marker-less file is wrapped once as a `legacy` block so old content survives the first write.

## Install vs. generate (who does what)

- **`install.sh`** (run once after clone): symlinks `pm-generate`, copies `lib/` into the
  framework dir, creates an empty `registry.jsonl` + `sessions/`, and seeds
  `~/.config/pm/config.json` from the template if absent. Idempotent.
- **`/pm-generate`** (run in Claude Code): detects tools, confirms slots, writes the real
  `config.json`, (re-)installs `lib/`, and renders the four `pm-*` skills. Re-runnable to
  change your slot mapping.
