---
name: pm-status
description: Cache-only PM briefing for the active session's project — reads existing project files (CONTEXT.md, CALENDAR.md, meetings.jsonl, LAST-SESSION.md) + cached notes, with NO live meeting/tracker sync. Always runs the logger hygiene guard first when a logger is configured. Rerunnable anytime. Use for "where do things stand", "/pm-status", or a quick mid-session recap.
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
- **Named tools:** `{{framework_root}}/lib/config.sh` (`pm_load_config`) exposes the tool registry; the guard branches on `pm_tool_defined logs` + `pm_tool_defined todo`. Per-project scoping lives in `.pm/config.json` → `.tool_refs.<name>`. For Jamie's setup `logs`→clog and `todo`→crrt.
- **Per-project files** (in `<root>`): `.pm/config.json`, `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`, `LAST-SESSION.md`.
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
TODO_SCOPE=$(jq -r '.tool_refs.todo // ""' "$ROOT/.pm/config.json")   # crrt tag for this project
KEYWORDS=$(jq -r '.keywords | join(" ")' "$ROOT/.pm/config.json")
```

### Step 2 — GUARD (mandatory, always first action of substance)

**This is a standing hygiene guard and must run on every `/pm-status`.** It keeps the log and task list current regardless of what else happens. Both halves are guarded independently:

1. **`tool:logs` sweep** — **if `pm_tool_defined logs` is false:** skip and print "tool:logs not defined — skipping hygiene sweep." **Else:** invoke the `logs` provider's sweep/backfill in **backfill mode** — for Jamie's `clog`, run [`clog-sweep`](../clog-sweep/SKILL.md) ("clog it"): scan the session for unlogged state-changes and auto-write the missing entries with paired LEARNINGs. _related: `pm_tool_skills logs`._
2. **`tool:todo` hygiene** — **if `pm_tool_defined todo` is false:** skip and print "tool:todo not defined — skipping task hygiene." **Else:** update the `todo` provider (Jamie: `crrt`) — complete tasks finished this session, add new tasks surfaced, and add a one-line journal note if meaningful work happened. Tag new tasks with `$TODO_SCOPE`.

Do not skip the guard even if the briefing was requested moments ago.

### Step 3 — Print the briefing (cached files only — NO live sync)

Read and synthesize from cache only: `LAST-SESSION.md` (lead with this), `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`.

`LAST-SESSION.md` holds **one block per session** (`<!-- PM:SESSION <id> START -->`). Lead with this session's own block (`$SID` from Step 1) if present, else the most recent; note other sessions' blocks as concurrent work.

- **Status & recent decisions** — from `LAST-SESSION.md` + cached `tool:logs` entries if present (no live `tool:tasks` call)
- **Open tasks / next actions** — `tool:todo` tagged `$TODO_SCOPE` (`crrt list -f "$TODO_SCOPE"` — local, allowed) + cached `CONTEXT.md`. Do **not** hit `tool:tasks`/`tool:github` live; that is `/pm-start`.
- **Upcoming** — `CALENDAR.md` as it stands (not regenerated)
- **Recent meetings** — last few pointers from `meetings.jsonl` — _related: `pm_tool_skills meetings`_
- **Focus today** — synthesized, leading from `LAST-SESSION.md` next-up
- **Quick links** — from `CONTEXT.md`

If `CALENDAR.md` / `meetings.jsonl` look stale, note that `/pm-start` will refresh them — do **not** sync here.

### Step 4 — Log it — `tool:logs`

- **If `pm_tool_defined logs` is false:** skip with a note.
- **Else:** record via the `logs` provider (Jamie: `clog`): `clog ACTION "pm-status: cache-only briefing for '<name>' (guard ran: sweep + todo)"`.

## Rules

- **CACHE-ONLY.** No live `tool:meetings` fetch, no live `tool:tasks`/`tool:calendar` queries, no live `tool:email` scan, no `CALENDAR.md` regeneration. Reads cached files + local `tool:todo` only.
- **The guard always runs first** (`tool:logs` sweep + `tool:todo` hygiene, each guarded by `pm_tool_defined`) — this is the whole point of routing hygiene through `/pm-status`. When a guard tool is undefined, skip that half and say so.
- **Rerunnable.** Safe to call repeatedly in a session.
- **No commit/push.**

## Signal Keywords
<!-- Comma-separated terms the skills collector uses to attribute learnings to this skill -->
pm-status, pm-framework, project-status, cache-only, briefing, recap, hygiene-guard, project-manager, where-things-stand
