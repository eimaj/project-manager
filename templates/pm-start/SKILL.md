---
name: pm-start
description: Open a PM-framework project for the session — sets the per-session marker, runs LIVE sync (meeting catch-up + tracker due dates), and prints the morning briefing. Run once at session open. Use when starting work on a project, "pick up where I left off on X", or "/pm-start @path".
---

# pm-start — Open a Project (live sync + briefing)

> Rendered by `/pm-generate` from a tool-agnostic template. The bracketed slot names
> were filled from your mapping; the logic only ever talks to slots, and degrades when
> a slot is `none`.

## Trigger

**Use when:** opening a project for a work session — "start on <project>", "pick up where I left off", "/pm-start @path/to/root". Run once at session open.
**Do NOT use when:** you just want a rerunnable read-only briefing with no live network sync → use `/pm-status`. Or wrapping up → use `/pm-end`.
**Inputs expected:** `@<path>` to the project root on first run in a session (sets the marker). Subsequent commands in the same session read the marker.
**Outputs produced:** session marker `{{framework_root}}/sessions/<session-id>`; new meeting pointers appended to `<root>/meetings.jsonl`; regenerated `<root>/CALENDAR.md`; a printed briefing; and a paste-ready `/rename` + `/color` block.

## Related Skills

- [`pm-init`](../pm-init/SKILL.md) — one-time scaffold (run before the first `/pm-start`)
- [`pm-status`](../pm-status/SKILL.md) — cache-only rerunnable briefing
- [`pm-end`](../pm-end/SKILL.md) — EOD capture

---

## Framework facts (shared across all four pm-* skills)

- **Project identity = its folder root path.** Registry: `{{framework_root}}/registry.jsonl` (deduped by `root`).
- **Per-session marker:** `{{framework_root}}/sessions/<session-id>` holds the active project root path, where `<session-id>` comes from `{{framework_root}}/lib/session.sh`. **This skill writes it.** Concurrent sessions each hold their own.
- **Capability slots (your mapping):** meeting source = **{{meeting_source}}**, tracker = **{{tracker}}**, logger = **{{logger}}**, email = **{{email}}**, notes store root = **{{notes_root}}**.
- **Per-project files** (in `<root>`): `.pm/config.json`, `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`, `LAST-SESSION.md`.
- **Meetings = pointers, not copies.** The meeting archive lives under `{{notes_root}}/meetings`. The project's `meetings.jsonl` holds only pointers `{meeting_id, date, title, path}`.

## Steps

### Step 1 — Resolve the project and write the session marker

```bash
SID=$({{framework_root}}/lib/session.sh)        # robust session id ($CLAUDE_SESSION_ID may be unset in the shell)
MARKER="{{framework_root}}/sessions/$SID"
# If the user passed @<path>, that path is the project root. Else read existing marker:
ROOT="<resolved @path>"                          # or: ROOT="$(cat "$MARKER" 2>/dev/null)"
test -f "$ROOT/.pm/config.json" || { echo "Not a PM project (run /pm-init): $ROOT"; exit 1; }
mkdir -p "{{framework_root}}/sessions"
printf '%s\n' "$ROOT" > "$MARKER"
```

Load config into shell vars for later steps:

```bash
MEETING_REF=$(jq -r '.meeting_ref // ""' "$ROOT/.pm/config.json")
TRACKER_REF=$(jq -r '.tracker_ref // ""' "$ROOT/.pm/config.json")
EMAIL_REF=$(jq -r '.email_ref // ""' "$ROOT/.pm/config.json")
NOTES_REF=$(jq -r '.notes_ref // ""' "$ROOT/.pm/config.json")
KEYWORDS=$(jq -r '.keywords | join(" ")' "$ROOT/.pm/config.json")
NAME=$(jq -r '.name // ""' "$ROOT/.pm/config.json")
SESSION_COLOR=$(jq -r '.session_color // ""' "$ROOT/.pm/config.json")
```

(Session branding — `/rename` + `/color` — is printed at the end in Step 8 for the user to paste; slash commands can't be invoked programmatically.)

### Step 2 — Meeting catch-up (LIVE) — meeting_source slot

- **If the `meeting_source` slot is `none`:** **skip meeting catch-up entirely.** Print: "meeting_source slot is none — skipping meeting sync; meetings.jsonl will not be updated." Do not attempt any meeting fetch.
- **Else:** pull recent meetings from **{{meeting_source}}** and archive them under `{{notes_root}}/meetings` (transcripts + an `import-log.jsonl` index). **Run inline in the main session — MCP-backed meeting tools can fail silently inside subagents.**

### Step 3 — Append new meeting pointers — meeting_source slot

- **If the `meeting_source` slot is `none`:** skip (no source to map from).
- **Else:** map the project's meetings (those matching `MEETING_REF`, or falling back to keyword title match against `KEYWORDS` when `MEETING_REF` is blank) to archived transcript paths, then append only NEW pointers to `<root>/meetings.jsonl` (dedupe by `meeting_id`):

  ```bash
  EXISTING=$(jq -r '.meeting_id' "$ROOT/meetings.jsonl" 2>/dev/null | sort -u)
  # for each new id in the archive index NOT already present, append a pointer:
  #   {"meeting_id":..,"date":..,"title":..,"path":"{{notes_root}}/meetings/<file>"}
  ```

  Never duplicate transcripts — store pointers only. If `MEETING_REF` is blank, note it as a TODO.

### Step 3b — Inbox scan (LIVE) — email slot

- **If the `email` slot is `none`:** **skip the inbox scan** and say so. Print: "the `email` slot is `none` — skip the inbox scan and say so." Do not attempt any mail fetch.
- **Else:** pull this project's action items / commitments / threads needing a response from **{{email}}**, filtered by `EMAIL_REF` (the project's label/folder/sender filter), falling back to keyword title/subject match against `KEYWORDS` when `EMAIL_REF` is blank. **Run inline in the main session — MCP-backed mail tools can fail silently inside subagents.** Surface the results in the briefing (Step 6); do not write them to a project file. If `EMAIL_REF` is blank, note it as a TODO.

### Step 4 — Regenerate CALENDAR.md — tracker slot

- **If the `tracker` slot is `none`:** **skip the live due-date pull.** Leave the Synced section as `_(tracker slot is none — no due dates synced)_` and **preserve everything below the `<!-- PM:MANUAL -->` marker verbatim.** Say so in the briefing.
- **Else:** pull forward-looking due dates for `TRACKER_REF` from **{{tracker}}**, rewrite the **Synced** section above the marker, and **preserve everything below it verbatim** (hand-added dated items). Sort synced entries by date. If `TRACKER_REF` is blank, leave Synced as `_(no tracker project configured — TODO)_` and still preserve Manual.

  ```bash
  MARKER='<!-- PM:MANUAL'
  # preserved="$(sed -n "/$MARKER/,\$p" "$ROOT/CALENDAR.md")"   # marker line onward, kept as-is
  ```

### Step 5 — Read handoff + open work

Read, in order: `<root>/LAST-SESSION.md` (where I left off — lead with this), `<root>/CONTEXT.md` (stable overview).

`LAST-SESSION.md` holds **one block per session** (`<!-- PM:SESSION <id> START -->`). Lead with **this session's own block** if present (`$SID` from Step 1), else the most recent. Surface other sessions' blocks briefly as "other recent sessions on this project" so concurrent work is visible.

```bash
awk -v s="<!-- PM:SESSION $SID START -->" -v e="<!-- PM:SESSION $SID END -->" \
  '$0==s{f=1;next} $0==e{f=0} f' "$ROOT/LAST-SESSION.md"
grep -oE 'PM:SESSION [^ ]+ START' "$ROOT/LAST-SESSION.md" | grep -v " $SID " || true
```

Then pull open work:

- **Tracker tasks** — **if the `tracker` slot is `none`:** skip; note "no tracker — tasks tracked manually in CONTEXT/notes". **Else:** list open items for `TRACKER_REF` (and/or `NOTES_REF`) from **{{tracker}}**.
- **Recent activity** — **if the `logger` slot is `none`:** skip. **Else:** pull recent **{{logger}}** entries matching `KEYWORDS` / `NOTES_REF` (last few days) for recent decisions/actions.

### Step 6 — Print the briefing

Print these sections in order (omit a source's section when its slot is `none`, with a one-line note that it was skipped):

- **Status & recent decisions** — from recent logger entries + tracker state
- **Open tasks / next actions** — tracker items (+ notes)
- **Inbox needing a response** — action items / commitments / threads from **{{email}}** (omit when the `email` slot is `none`)
- **Upcoming** — `CALENDAR.md`
- **Recent meetings** — last few pointers from `meetings.jsonl`
- **Focus today** — your synthesis (lead from LAST-SESSION next-up)
- **Quick links** — tracker project URL, repos, key docs from `CONTEXT.md`

### Step 7 — Log it — logger slot

- **If the `logger` slot is `none`:** skip.
- **Else:** record via **{{logger}}**: `pm-start: opened '<name>' — synced N new meetings, regenerated CALENDAR, briefed`.

### Step 8 — Print the session branding block (paste to apply)

`/rename` and `/color` cannot be invoked programmatically — print them as a copy-paste block:

```
/rename <NAME>
/color <SESSION_COLOR>
```

- `<NAME>` is the project name; `<SESSION_COLOR>` is `session_color` from config.
- **Valid Claude Code colors:** `red, blue, green, yellow, purple, orange, pink, cyan, default`. If `session_color` is blank, print only `/rename`. If it holds a non-valid value, map it to the nearest valid color and note the substitution.

## Rules

- **This is the LIVE-sync entry point.** `/pm-status` is cache-only; do not duplicate live sync there.
- **Meeting catch-up runs inline** — never delegate the meeting fetch to a subagent (MCP can fail silently there).
- **Every slot has an explicit `none` branch** — when a slot is `none`, skip its sync and say so in the briefing. Never fabricate data for a disabled slot.
- **CALENDAR regeneration preserves manual entries** below the `<!-- PM:MANUAL -->` marker. Never drop them.
- **meetings.jsonl is pointers only** — dedupe by `meeting_id`, never copy transcript bodies into the project.
- **Blank config values are TODOs**, surfaced in the briefing, not fabricated.
- **No commit/push.**

## Signal Keywords
<!-- Comma-separated terms the skills collector uses to attribute learnings to this skill -->
pm-start, pm-framework, project-briefing, morning-brief, live-sync, meeting-sync, calendar-regen, session-marker, pick-up-where-left-off, project-manager
