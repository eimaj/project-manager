---
name: pm-status
description: Cache-only PM briefing for the active session's project — reads existing project files (CONTEXT.md, CALENDAR.md, meetings.jsonl, LAST-SESSION.md) + cached notes, with NO live meeting/tracker sync. Always runs the logs-sweep + todo-hygiene guard first (each half guarded by its own tool). Rerunnable anytime. Use for "where do things stand", "/pm-status", or a quick mid-session recap.
---

# pm-status — Cache-Only Briefing (rerunnable)

> Rendered by `/pm-generate`. This skill addresses capabilities by **named tool**
> (`tool:<name>`) and resolves each at runtime via `{{framework_root}}/lib/config.sh` —
> only `{{framework_root}}` and `{{notes_root}}` are substituted at render time. An
> undefined tool (provider `none`) degrades with a printed note.

## Default tool names

The framework imposes no fixed role vocabulary — your tools are whatever names
`~/.config/pm/config.json` declares. This skill references the **default name set
`/pm-generate` suggests**: `meetings`, `calendar`, `email`, `tasks`, `github`, `todo`,
`logs`, `notes`. This cache-only briefing only touches `tool:logs` + `tool:todo` (the
guard) and reads cached files otherwise. If you renamed a tool, adjust the `tool:<name>`
references below.

## Trigger

**Use when:** you want a quick, rerunnable read of where the active project stands — "what's the status", "recap", "/pm-status" — without paying for a live network sync.
**Do NOT use when:** opening the session / needing fresh meeting+tracker data → use `/pm-start`. Or wrapping up → use `/pm-end`.
**Inputs expected:** none — resolves the project from the per-session marker written by `/pm-start`.
**Outputs produced:** backfilled logger entries (the guard, if a logger is configured), and a printed briefing from cached files only.

## Related Skills

- [`pm-start`](../pm-start/SKILL.md) — the live-sync open; run it first to set the marker
- [`pm-end`](../pm-end/SKILL.md) — EOD capture

---

## Framework facts (shared across all four pm-* skills)

- **Per-session marker:** `{{framework_root}}/sessions/<session-id>` holds the active project root (`<session-id>` via `{{framework_root}}/lib/session.sh`). **This skill reads it** (does not write it).
- **Named tools:** `{{framework_root}}/lib/config.sh` (`pm_load_config`) exposes the tool registry; the guard branches on `pm_tool_defined logs` + `pm_tool_defined todo`. Each tool resolves to its configured provider via `pm_tool_provider <name>`. Per-project scoping lives in `.pm/config.json` → `.tool_refs.<name>`.
- **Per-project files** (in `<root>`): `.pm/config.json`, `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`, `LAST-SESSION.md`, `reports/`, `briefs/`.
- **Project-local reports vs a tool's global root.** A project's OWN report artifacts live under **`<root>/reports/`** (seeded by `/pm-init`). This is distinct from a tool's **global** `root` (`pm_tool_root <name>` — the shared, cross-project sink). When a pm-* skill writes a report/output **for the active project**, target `<root>/reports/`; a tool's `root` / `pm_tool_root_or_notes <name>` is for that tool's cross-project archive.
- **Project-local briefs.** A project's `/orchestrate-brief` output lives under its **`briefs_dir`** (`.pm/config.json`, default **`<root>/briefs/`**, seeded by `/pm-init`), named `YYYY-MM-DD-<TICKET>-<slug>.md` — a per-project artifact dir like `<root>/reports/`. `/orchestrate-brief` produces `brief.md` at the orchestrate default `{artifact_root}/runs/<session_id>/`; resolve `briefs_dir` and relocate it there (`mkdir -p` + `mv`) — confirm the destination when interactive, move silently in automated runs — then pass the new path to `/orchestrate`. **Commit the relocated brief** — briefs live untracked in the project tree and a concurrent session can wipe an uncommitted one. Never modify orchestrate's global `artifact_root`.
- **Per-project tool override.** `.pm/config.json` MAY carry an optional `tools{}` block; after `pm_load_project <root>` the accessors resolve the **effective** tool = project override ?? global registry (per field), scoped to this project only — never mutating the global `~/.config/pm/config.json`. Precedence: project override > global > undefined (degrade).
- **Cache-only:** this skill reads existing files + `tool:todo`. It performs **NO** live `tool:meetings` / `tool:tasks` / `tool:calendar` / `tool:email` sync — that is `/pm-start`'s job.
- **Collaborators roster (`.pm/config.json` → `collaborators`):** a hand-maintained array (`{name, role, slack, github, email}`) `/pm-start` renders as a quick-reference. A local lookup index agents read to resolve teammates without an MCP call; absent/empty = TODO.

## Steps

### Step 1 — Resolve the project from the marker

```bash
source "{{framework_root}}/lib/config.sh"
pm_load_config || { echo "pm: no config — run /pm-generate first."; exit 1; }
SID=$("{{framework_root}}/lib/session.sh")        # same resolver pm-start used to write the marker
ROOT="$(cat "{{framework_root}}/sessions/$SID" 2>/dev/null)"
test -f "$ROOT/.pm/config.json" || { echo "No active PM project this session — run /pm-start @<path> first."; exit 1; }
TODO_SCOPE=$(jq -r '.tool_refs.todo // ""' "$ROOT/.pm/config.json")   # todo tag/list for this project
KEYWORDS=$(jq -r '.keywords | join(" ")' "$ROOT/.pm/config.json")
```

### Step 2 — GUARD (mandatory, always first action of substance)

**This is a standing hygiene guard and must run on every `/pm-status`.** It keeps the log and task list current regardless of what else happens. Both halves are guarded independently:

1. **`tool:logs` sweep** — **if `pm_tool_defined logs` is false:** skip and print "tool:logs not defined — skipping hygiene sweep." **Else:** invoke the `logs` tool's configured provider in **backfill mode** (its sweep/backfill skill — see `pm_tool_skills logs`): scan the session for unlogged state-changes and auto-write the missing entries. _related: `pm_tool_skills logs`._
2. **`tool:todo` hygiene** — **if `pm_tool_defined todo` is false:** skip and print "tool:todo not defined — skipping task hygiene." **Else:** update the `todo` tool's configured provider — complete tasks finished this session, add new tasks surfaced, and add a one-line journal note if meaningful work happened. Tag new tasks with `$TODO_SCOPE`.

Do not skip the guard even if the briefing was requested moments ago.

### Step 3 — Print the briefing (cached files only — NO live sync)

Read and synthesize from cache only: `LAST-SESSION.md` (lead with this), `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`.

`LAST-SESSION.md` holds **one block per session** (`<!-- PM:SESSION <id> START -->`). Lead with this session's own block (`$SID` from Step 1) if present, else the most recent; note other sessions' blocks as concurrent work.

- **Status & recent decisions** — from `LAST-SESSION.md` + cached `tool:logs` entries if present (no live `tool:tasks` call)
- **Open tasks / next actions** — `tool:todo` tagged `$TODO_SCOPE` (a local read against its provider, allowed) + cached `CONTEXT.md`. Do **not** hit `tool:tasks`/`tool:github` live; that is `/pm-start`.
- **Upcoming** — `CALENDAR.md` as it stands (not regenerated)
- **Recent meetings** — last few pointers from `meetings.jsonl` — _related: `pm_tool_skills meetings`_
- **Focus today** — synthesized, leading from `LAST-SESSION.md` next-up
- **Quick links** — from `CONTEXT.md`

If `CALENDAR.md` / `meetings.jsonl` look stale, note that `/pm-start` will refresh them — do **not** sync here.

### Step 4 — Log it — `tool:logs`

- **If `pm_tool_defined logs` is false:** skip with a note.
- **Else:** record via the `logs` tool's configured provider an action entry like: `pm-status: cache-only briefing for '<name>' (guard ran: sweep + todo)`.

## Rules

- **CACHE-ONLY.** No live `tool:meetings` fetch, no live `tool:tasks`/`tool:calendar` queries, no live `tool:email` scan, no `CALENDAR.md` regeneration. Reads cached files + local `tool:todo` only.
- **The guard always runs first** (`tool:logs` sweep + `tool:todo` hygiene, each guarded by `pm_tool_defined`) — this is the whole point of routing hygiene through `/pm-status`. When a guard tool is undefined, skip that half and say so.
- **Rerunnable.** Safe to call repeatedly in a session.
- **No commit/push.**

## Signal Keywords
<!-- Comma-separated terms the skills collector uses to attribute learnings to this skill -->
pm-status, pm-framework, project-status, cache-only, briefing, recap, hygiene-guard, project-manager, where-things-stand
