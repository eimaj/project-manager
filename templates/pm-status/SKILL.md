---
name: pm-status
description: Cache-only PM briefing for the active session's project — reads existing project files (CONTEXT.md, CALENDAR.md, meetings.jsonl, LAST-SESSION.md) + cached notes, with NO live meeting/tracker sync. Always runs the logger hygiene guard first when a logger is configured. Rerunnable anytime. Use for "where do things stand", "/pm-status", or a quick mid-session recap.
---

# pm-status — Cache-Only Briefing (rerunnable)

> Rendered by `/pm-generate` from a tool-agnostic template. Slot names below were
> filled from your mapping; logic talks to slots only and degrades when a slot is `none`.

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
- **Capability slots (your mapping):** meeting source = **{{meeting_source}}**, tracker = **{{tracker}}**, logger = **{{logger}}**, notes store root = **{{notes_root}}**.
- **Per-project files** (in `<root>`): `.pm/config.json`, `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`, `LAST-SESSION.md`.
- **Cache-only:** this skill reads existing files. It performs **NO** live meeting or tracker sync — that is `/pm-start`'s job.

## Steps

### Step 1 — Resolve the project from the marker

```bash
SID=$({{framework_root}}/lib/session.sh)        # same resolver pm-start used to write the marker
ROOT="$(cat "{{framework_root}}/sessions/$SID" 2>/dev/null)"
test -f "$ROOT/.pm/config.json" || { echo "No active PM project this session — run /pm-start @<path> first."; exit 1; }
NOTES_REF=$(jq -r '.notes_ref // ""' "$ROOT/.pm/config.json")
KEYWORDS=$(jq -r '.keywords | join(" ")' "$ROOT/.pm/config.json")
```

### Step 2 — GUARD (hygiene; logger slot)

**This is a standing hygiene guard.** Its purpose is to keep the logger and any task list current regardless of what else happens.

- **If `{{logger}}` is `none`:** **skip the logger sweep** and print "logger slot is none — skipping hygiene sweep." (You may still do the lightweight cache-only briefing in Step 3.)
- **Else:** invoke the **{{logger}}** sweep/backfill flow — scan the session for unlogged state-changes and auto-write the missing entries. If your logger has no sweep concept, at minimum record one summary entry of work done this session.

Do not skip the guard (when a logger exists) even if the briefing was requested moments ago.

### Step 3 — Print the briefing (cached files only — NO live sync)

Read and synthesize from cache only: `LAST-SESSION.md` (lead with this), `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`.

`LAST-SESSION.md` holds **one block per session** (`<!-- PM:SESSION <id> START -->`). Lead with this session's own block (`$SID` from Step 1) if present, else the most recent; note other sessions' blocks as concurrent work.

- **Status & recent decisions** — from `LAST-SESSION.md` + cached logger entries if present (no live tracker call)
- **Open tasks / next actions** — from cached notes / `CONTEXT.md` (do not hit the tracker live; that is `/pm-start`)
- **Upcoming** — `CALENDAR.md` as it stands (not regenerated)
- **Recent meetings** — last few pointers from `meetings.jsonl`
- **Focus today** — synthesized, leading from `LAST-SESSION.md` next-up
- **Quick links** — from `CONTEXT.md`

If `CALENDAR.md` / `meetings.jsonl` look stale, note that `/pm-start` will refresh them — do **not** sync here.

### Step 4 — Log it — logger slot

- **If `{{logger}}` is `none`:** skip.
- **Else:** record via **{{logger}}**: `pm-status: cache-only briefing for '<name>' (guard ran)`.

## Rules

- **CACHE-ONLY.** No live meeting fetch, no live tracker queries, no `CALENDAR.md` regeneration. Reads files only.
- **The guard runs first when a logger exists** — this is the whole point of routing hygiene through `/pm-status`. When `{{logger}}` is `none`, skip it and say so.
- **Rerunnable.** Safe to call repeatedly in a session.
- **No commit/push.**

## Signal Keywords
<!-- Comma-separated terms the skills collector uses to attribute learnings to this skill -->
pm-status, pm-framework, project-status, cache-only, briefing, recap, hygiene-guard, project-manager, where-things-stand
