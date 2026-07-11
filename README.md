# pm — a generator for your own tool-agnostic PM skill set

`pm` is a Claude Code skill package whose centerpiece, **`/pm-generate`**, audits the tools
you already have and writes a *personalized* project-management workflow into your
`~/.claude`: a `pm-init` / `pm-start` / `pm-status` / `pm-end` skill set built around **the
tools you name** — no one else's tools or hardcoded paths.

The workflow it generates gives you **per-project context, live session sync, and clean
handoffs** across long-running work — including **concurrent sessions** in separate tabs that
never clobber each other's state.

---

## How it works

### The named-tool registry (the core idea)

There are **no fixed roles.** Your personal config carries a `tools` map keyed by **names you
choose**. Each name maps one tool to a concrete backend plus optional output and skill links:

```jsonc
"tools": {
  "<name>": {
    "provider": "<mcp/cli/skill id, or \"none\">",  // required; "none"/blank ⇒ tool degrades
    "root": "<abs path>",                            // optional output/notes sink; tools MAY share one
    "skills": ["skill-a", "skill-b"]                 // optional related-skill cross-refs (advisory)
  }
}
```

The map is dynamic and arbitrary-N — several tools may cover the same "role" (`todo` → `crrt`
and `tasks` → `linear` are two distinct tools). The generated skills **address tools by NAME**
(`tool:tasks`, `tool:meetings`) and resolve name → provider at runtime. An **undefined** name,
or one whose `provider` is `none`/blank, **degrades gracefully** — the skill skips that
capability and says so in the briefing rather than failing or fabricating data. `version` and
`paths` are reserved framework keys, not tools. See [docs/SLOTS.md](docs/SLOTS.md).

### `/pm-generate` flow

`/pm-generate` runs an **audit → group → walk-through**:

1. **Audit** your active MCP servers (`claude mcp list`) and installed skills
   (`~/.claude/skills/*`) — the raw candidates, no assumptions about what each is for.
2. **Group** the detected backends and skills by capability type (meetings, calendar, email,
   tasks, todo, logs, github, notes) with an **advisory** heuristic — a starting point, not a
   constraint. Unrecognized servers stay assignable.
3. **Walk through** each group with you: include it?, **name** the tool, pick its notes
   **root** (shareable — several tools can point at one folder), confirm its **provider**, and
   multi-select the **skills** to link. `none` is always allowed.
4. **Write** a gitignored personal config (schema v2, dynamic `tools` map) at
   `~/.config/pm/config.json`.
5. **Install** the framework `lib/` and initialize empty runtime state.
6. **Render** the four `pm-*` templates into working skills (near-static — only your
   `framework_root` / `notes_root` paths are baked in; tool identity stays in the config).
7. **Summarize** which tools were wired and which groups were skipped or degraded.

### The generated session lifecycle

| Skill | When | What it does | Network |
|---|---|---|---|
| **`pm-init`** | once per project | scaffolds `.pm/config.json`, `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`; upserts the registry (deduped by root). Flows straight into `pm-start`. | none |
| **`pm-start`** | once at session open | writes the per-session marker, **live sync** (meeting catch-up + inbox scan + task due dates, each gated on the relevant tool being defined), prints the briefing + a paste-ready `/rename`+`/color` block | live |
| **`pm-status`** | anytime, rerunnable | hygiene guard first, then a briefing from cached files only | none |
| **`pm-end`** | wrapping up | hygiene guard, session summary, per-session `LAST-SESSION.md` handoff block, optional per-session git commit | none |

### The `collaborators` index

Beyond the CSV `team` field, each project's `.pm/config.json` carries a hand-maintained
**`collaborators`** array — a per-project roster of `{name, role, slack, github, email}`:

```json
"collaborators": [
  { "name": "Jane Doe", "role": "Backend",
    "slack": "https://<workspace>.slack.com/team/U0123ABC",
    "github": "janedoe", "email": "jane.doe@company.com" }
]
```

- **Seeded as `[]`** by `pm-init` and **preserved verbatim across re-init** (it is never rebuilt
  from a flag or an init question — you populate and maintain it by hand).
- `pm-start` renders it as a quick-reference **Name | Role | Slack | GitHub** table; absent/empty
  prints a TODO.
- It is a **local, read-only lookup index** — agents read it from config to resolve a teammate's
  handle **without an MCP call**. MCP is used only when *authoring* an entry. It is **not** a
  contact, distribution, or notification list — nobody is ever messaged from it.

### Multi-session / concurrency model

Two Claude Code tabs can work the same (or different) projects at once without clobbering each
other. The framework isolates per-session state and locks the shared state it must touch.

- **Session identity** — `lib/session.sh` resolves a stable id, preferring
  `CLAUDE_CODE_SESSION_ID` (a real per-tab UUID, stable within a tab and distinct across tabs),
  then falling through `CLAUDE_SESSION_ID` → `PM_SESSION_PID` → `TERM_SESSION_ID` → a minted UUID
  → a controlling-tty anchor → `shell-$PPID`. When no harness var is set, `pm-start` (the only
  writer) **mints** a UUID once and persists it under `sessions/.mint/<anchor>`; `session.sh` is a
  pure reader that rediscovers it, so `pm-start`/`pm-status`/`pm-end` all resolve the identical id.
- **Per-session marker** — `pm-start` writes `sessions/<id>` = the active project root; `pm-status`
  and `pm-end` only read it. Each tab holds its own marker.
- **Per-session handoff** — `LAST-SESSION.md` holds **one block per session**
  (`<!-- PM:SESSION <id> START -->`). `lib/handoff-write.sh` replaces only the calling session's
  block and preserves every other session's, under an atomic `mkdir` lock; a pre-existing
  marker-less file is wrapped once as a `legacy` block.
- **Locked shared writes** — `lib/with-lock.sh` (atomic-`mkdir` acquire → short retry →
  break a >30s stale lock → fail loud) guards `meetings.jsonl` append (the dedupe read + append
  run **inside** one lock) and `CALENDAR.md` regeneration (temp file + atomic `mv`). `scaffold.sh`
  uses the same helper for the registry upsert.
- **Per-session commit branch** — `pm-end`'s optional git step (`lib/session-commit.sh`) commits
  **only the project folder** on a per-session branch `chore/$DAY-$SLUG-pm-<shortsid>` (short,
  ref-safe form of the session id), so concurrent tabs never race on one shared ref or index. The
  working tree is shared, so it captures the branch you were on and restores it afterward. Never
  pushes, never targets `main`. Reconcile the per-session branches into one branch/PR at EOD.
- **`auto_ship` (per-project, opt-in)** — a boolean in each project's `.pm/config.json`, **default
  `false`**. When `false`, `pm-end` stops after the local per-session commit and you reconcile the
  branches manually at EOD (above). Set it to `true` to have `pm-end` **auto-ship** each session's
  branch via a PR — push the branch, `gh pr create` against the repo's default base, then
  `gh pr merge --merge --delete-branch`. It ships only when a commit was actually made and a git
  remote exists; it never pushes `main` directly and never bypasses hooks. Seeded as `false` by
  `pm-init` and **preserved across re-init** (like `collaborators`).

**Isolated per session:** the session marker, the minted id, the `LAST-SESSION.md` block, and the
`pm-end` commit branch. **Shared (guarded by locks):** `meetings.jsonl`, `CALENDAR.md`, the git
working copy, and the global `registry.jsonl`.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/SLOTS.md](docs/SLOTS.md) for full detail.

---

## Structure

### Repo layout (source of truth)

```
pm/
  install.sh                 # idempotent installer (symlink + lib + state + starter config)
  lib/                       # tool-agnostic bash, installed into the framework dir
    session.sh               #   resolve a stable per-session id (read-only)
    with-lock.sh             #   reusable atomic mkdir lock (retry/stale-break/fail-loud)
    scaffold.sh              #   scaffold a project's files; upsert the registry
    handoff-write.sh         #   atomic per-session LAST-SESSION.md block update
    session-commit.sh        #   per-session pm-end commit branch
    config.sh                #   read the personal config, expose generic tool accessors
  templates/pm-{init,start,status,end}/SKILL.md   # placeholder skills, RENDERED by pm-generate
  skills/pm-generate/        # the generator skill itself (symlinked by install.sh)
  docs/                      # ARCHITECTURE.md, SLOTS.md
  config/config.example.json # personal-config template (schema v2, named-tool registry)
  tests/run.sh               # pure-bash test suite (bash + jq only)
```

### On-disk install layout

```
~/.claude/skills/
  pm-generate -> <repo>/skills/pm-generate   # SYMLINK (clog-style; tracks the repo)
  pm-{init,start,status,end}/SKILL.md        # RENDERED real files (your framework paths baked in)

~/.claude/pm/                 # framework dir — lib + runtime state ONLY (no skills)
  lib/                        # copied from the repo
  registry.jsonl              # project list (append-only, deduped by root) — gitignored state
  sessions/<id>               # per-session marker → active project root — gitignored state

~/.config/pm/config.json      # personal named-tool registry + paths — gitignored, never committed
<notes_root>/                 # default output sink (paths.notes_root; any tool without its own root)
```

### Per-project files (in a project root)

| File | Written by | Purpose |
|---|---|---|
| `.pm/config.json` | `pm-init` (always rewritten) | canonical per-project config (`tool_refs`, team, keywords, `collaborators`, `auto_ship`, `session_color`) |
| `CONTEXT.md` | `pm-init` seed (never clobbered) | stable hand-edited overview |
| `CALENDAR.md` | `pm-init` seed; `pm-start` regen | Synced due dates; manual entries below `<!-- PM:MANUAL -->` preserved |
| `meetings.jsonl` | `pm-start` appends | `{meeting_id, date, title, path}` pointers — never transcript copies |
| `LAST-SESSION.md` | `pm-end` (per-session block) | forward handoff; one block per session, never cross-clobbered |

---

## Benefits

- **Context that survives session boundaries** — per-project `CONTEXT.md` + `LAST-SESSION.md`
  handoffs mean you resume exactly where you left off.
- **Live sync at session open** — meetings, inbox action items, and task due dates pulled
  automatically by `pm-start`.
- **Cheap status, expensive only when needed** — `pm-status` is cache-only/rerunnable; network
  work is isolated to `pm-start`.
- **Clean EOD capture** — `pm-end` writes a structured handoff without clobbering other sessions' blocks.
- **Safe concurrency** — per-session ids, markers, handoff blocks, and commit branches plus locked
  shared writes let multiple tabs run at once without lost updates.
- **Tool-agnostic** — the named-tool registry means it works with *your* stack, not the author's.
- **Familiar install** — the same symlink + gitignored-config convention as
  [`clog`](https://github.com/eimaj/clog). *(Caveat: the **generated** `pm-*` skills are rendered as real
  files with your framework paths baked in — not pure symlinks like clog. Only `pm-generate` itself
  is symlinked. Re-running `/pm-generate` re-renders them.)*

## Why it might NOT be for everyone (honest take)

- **Heavy Claude Code + MCP investment.** If you don't use Claude Code skills or have no MCP
  servers, most of the value evaporates.
- **Best for long-running, multi-session projects.** For one-off tasks the per-project file
  sprawl (`.pm/`, `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`, `LAST-SESSION.md`) is overhead,
  not help.
- **Opinionated workflow.** It imposes a session lifecycle (init → start → status → end) and a
  handoff format; if your workflow differs, you'll fight it.
- **Full value needs at least a meeting tool + a task tool.** With neither defined it degrades
  to a glorified notes scaffolder.
- **Bash + symlinks.** macOS / Linux / WSL only; no native Windows support.
- **You maintain the generated skills.** Regenerating after upstream template changes is a manual
  re-run of `/pm-generate`.

---

## Quickstart

```bash
git clone <this-repo> ~/Code/pm
cd ~/Code/pm
./install.sh            # symlinks pm-generate, installs lib, inits state, seeds config
```

Then in Claude Code:

```
/pm-generate            # audit tools, name them, render your pm-* skills
/pm-init                # (in a project folder) onboard your first project
```

`install.sh` is idempotent — re-run it any time; it will not duplicate state.

## Requirements

- `bash`, `jq`
- Claude Code (for the skills + MCP detection)
- macOS / Linux / WSL

## License

MIT — see [LICENSE](LICENSE).
