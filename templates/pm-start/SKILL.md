---
name: pm-start
description: Open a PM-framework project for the session — sets the per-session marker, runs LIVE sync (meeting catch-up, upcoming calendar, task + GitHub due dates, inbox), and prints the morning briefing. Run once at session open. Use when starting work on a project, "pick up where I left off on X", or "/pm-start @path".
---

# pm-start — Open a Project (live sync + briefing)

> Rendered by `/pm-generate`. This skill addresses capabilities by **named tool**
> (`tool:<name>`) and resolves each at runtime via `{{framework_root}}/lib/config.sh` —
> only `{{framework_root}}` and `{{notes_root}}` are substituted at render time. A tool
> that is undefined (or whose provider is `none`) degrades with a printed note.

## Default tool names

The framework imposes no fixed role vocabulary — your tools are whatever names
`~/.config/pm/config.json` declares. This skill references the **default name set
`/pm-generate` suggests**: `meetings` (past/recorded), `calendar` (future/upcoming),
`email`, `tasks`, `github`, `todo`, `logs`, `notes`. If you renamed a tool at generate
time, adjust the `tool:<name>` references below to match.

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
- **Named tools, resolved at runtime.** `lib/config.sh` (`pm_load_config`) exposes the tool registry; each step branches on `pm_tool_defined <name>` and degrades with a note when a tool is undefined. Each tool's concrete backend is its **configured provider** (`pm_tool_provider <name>`) — the skills never hard-code one. Per-project scoping for a tool lives in `.pm/config.json` → `.tool_refs.<name>` (how THIS project is identified inside that tool's backend).
- **Per-project files** (in `<root>`): `.pm/config.json`, `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`, `LAST-SESSION.md`.
- **Meetings = pointers, not copies.** The meeting archive lives under `pm_tool_root_or_notes meetings` (the `meetings` tool's configured `root`, falling back to `$PM_NOTES_ROOT` when it has no explicit `root`). The project's `meetings.jsonl` holds only pointers `{meeting_id, date, title, path}`.
- **Collaborators roster (`.pm/config.json` → `collaborators`):** a hand-maintained array (`{name, role, slack, github, email}`) this skill renders as a quick-reference (Step 6). A local lookup index read from config — no live/MCP call at read time. Absent/empty = TODO.

## Steps

### Step 1 — Resolve the project and write the session marker

```bash
# Load the tool registry (accessors + framework paths) — required for every later step.
source "{{framework_root}}/lib/config.sh"
pm_load_config || { echo "pm: no config — run /pm-generate first."; exit 1; }

# Source the resolver so the mint write below reuses its EXACT anchor derivation (no drift).
. "{{framework_root}}/lib/session.sh"
SID="$(pm_session_id)"                            # prefers CLAUDE_CODE_SESSION_ID (a real UUID)

# Mint fallback: only when SID is a WEAK id (no harness session var was set). A weak id is
# tty-… or shell-…; a real harness id is a UUID and must be used verbatim (do NOT mint).
if [[ "$SID" =~ ^shell- || "$SID" =~ ^tty- ]]; then
  ANCHOR="$(pm_session_anchor)"                   # same anchor session.sh's mint lookup reads
  MINT_DIR="{{framework_root}}/sessions/.mint"
  MINT_FILE="$MINT_DIR/$ANCHOR"
  if [[ -r "$MINT_FILE" ]]; then
    SID="$(cat "$MINT_FILE")"                     # rediscover a sibling's earlier mint
  else
    SID="$(uuidgen | tr '[:upper:]' '[:lower:]')" # mint a fresh UUID, lowercase
    mkdir -p "$MINT_DIR"
    printf '%s\n' "$SID" > "$MINT_FILE"           # persist so session.sh + siblings agree
  fi
fi

MARKER="{{framework_root}}/sessions/$SID"
# If the user passed @<path>, that path is the project root. Else read existing marker:
ROOT="<resolved @path>"                          # or: ROOT="$(cat "$MARKER" 2>/dev/null)"
test -f "$ROOT/.pm/config.json" || { echo "Not a PM project (run /pm-init): $ROOT"; exit 1; }
mkdir -p "{{framework_root}}/sessions"
printf '%s\n' "$ROOT" > "$MARKER"
```

> **Why mint?** `session.sh` is a pure reader — with no harness session var (`CLAUDE_CODE_SESSION_ID` / `CLAUDE_SESSION_ID` / `PM_SESSION_PID` / `TERM_SESSION_ID`) it can only return a weak `tty-…`/`shell-$PPID` id, which collapses distinct sessions together. pm-start (the one skill that owns session-marker creation) mints a stable UUID once and persists it keyed by the shell's anchor (`{{framework_root}}/sessions/.mint/<anchor>`). Every later `session.sh` call in the same shell rediscovers it via its read-only mint lookup, so `/pm-status` and `/pm-end` resolve the identical id. When a real harness UUID is present, it is used directly and nothing is minted.

Load config into shell vars for later steps:

```bash
# Per-project tool refs — how THIS project is identified inside each tool's backend.
# A blank ref => that tool falls back to keyword matching against $KEYWORDS.
MEETINGS_SCOPE=$(jq -r '.tool_refs.meetings // ""' "$ROOT/.pm/config.json")  # e.g. a meetings-provider folder
CALENDAR_SCOPE=$(jq -r '.tool_refs.calendar // ""' "$ROOT/.pm/config.json")  # e.g. calendar/category filter
EMAIL_SCOPE=$(jq -r '.tool_refs.email    // ""' "$ROOT/.pm/config.json")     # e.g. an email label/folder
TASKS_SCOPE=$(jq -r '.tool_refs.tasks    // ""' "$ROOT/.pm/config.json")     # e.g. a tracker project
GITHUB_SCOPE=$(jq -r '.tool_refs.github  // ""' "$ROOT/.pm/config.json")     # e.g. owner/repo
TODO_SCOPE=$(jq -r '.tool_refs.todo      // ""' "$ROOT/.pm/config.json")     # e.g. a todo tag/list
KEYWORDS=$(jq -r '.keywords | join(" ")' "$ROOT/.pm/config.json")
NAME=$(jq -r '.name // ""' "$ROOT/.pm/config.json")
SESSION_COLOR=$(jq -r '.session_color // ""' "$ROOT/.pm/config.json")
COLLABORATORS=$(jq -c '.collaborators // []' "$ROOT/.pm/config.json")   # roster for the Step 6 quick-reference
```

(Session branding — `/rename` + `/color` — is printed at the end in Step 8 for the user to paste; slash commands can't be invoked programmatically.)

### Step 2 — Meeting catch-up (LIVE) — `tool:meetings`

- **If `pm_tool_defined meetings` is false:** skip meeting catch-up entirely. Print: "tool:meetings not defined — skipping meeting catch-up (import meetings by hand)." Do not attempt any meeting fetch.
- **Else:** run the catch-up **inline in the main session** — MCP-backed meeting tools can fail silently inside subagents. Invoke the `meetings` tool's configured provider (a meeting-import/catch-up flow — see `pm_tool_skills meetings`) to import new meetings into the archive at `pm_tool_root_or_notes meetings` (transcripts + an import-log index).
  - _related: run `pm_tool_skills meetings` — surface the tool's linked skills as discovery hints; never auto-invoke._

### Step 3 — Append new meeting pointers — `tool:meetings`

- **If `pm_tool_defined meetings` is false:** skip (no source to map from).
- **Else:** map the project's meetings (those matching `$MEETINGS_SCOPE`, or falling back to keyword title match against `$KEYWORDS` when `$MEETINGS_SCOPE` is blank) to archived transcript paths, then append only NEW pointers to `<root>/meetings.jsonl` (dedupe by `meeting_id`). **The dedupe read and the append run inside one lock** so two concurrent tabs can't both read "id absent" and both append the same pointer:

  ```bash
  ARCHIVE="$(pm_tool_root_or_notes meetings)"          # meetings archive root (the meetings tool's root, else $PM_NOTES_ROOT)
  source "{{framework_root}}/lib/with-lock.sh"
  append_new_pointers() {
    EXISTING=$(jq -r '.meeting_id' "$ROOT/meetings.jsonl" 2>/dev/null | sort -u)   # read INSIDE the lock
    # for each candidate meeting (scoped by $MEETINGS_SCOPE) whose meeting_id is NOT in $EXISTING, append one pointer:
    #   echo '{"meeting_id":..,"date":..,"title":..,"path":"'"$ARCHIVE"'/<file>"}' >> "$ROOT/meetings.jsonl"
  }
  mkdir -p "$ROOT/.pm"
  with_lock "$ROOT/.pm/.meetings.lock" append_new_pointers
  ```

  Never duplicate transcripts — store pointers only. If `$MEETINGS_SCOPE` is blank, note it as a TODO.

### Step 3b — Inbox scan (LIVE) — `tool:email`

- **If `pm_tool_defined email` is false:** skip the inbox scan and say so: "tool:email not defined — skipping inbox scan." Do not attempt any mail fetch.
- **Else:** pull this project's action items / commitments / threads needing a response from the `email` tool's configured provider, filtered by `$EMAIL_SCOPE` (the project's label/folder/sender filter), falling back to keyword subject match against `$KEYWORDS` when `$EMAIL_SCOPE` is blank. **Run inline in the main session — MCP-backed mail tools can fail silently inside subagents.** Surface the results in the briefing (Step 6); do not write them to a project file. If `$EMAIL_SCOPE` is blank, note it as a TODO.

### Step 4 — Regenerate CALENDAR.md — `tool:calendar` + `tool:tasks` + `tool:github`

The **Synced** section (above the `<!-- PM:MANUAL -->` marker) is rebuilt from up to three tools, each guarded independently; **everything below the marker is preserved verbatim** (hand-added dated items). Build the Synced body as two sub-sections (keep them separate — do not interleave):

- **Upcoming events** ← **`tool:calendar`**. If `pm_tool_defined calendar` is false, render this sub-section as `_(tool:calendar not defined — no events synced)_`. Else pull forward-looking events from its configured provider, scoped by `$CALENDAR_SCOPE` (fallback keyword match on `$KEYWORDS`).
- **Due dates** ← **`tool:tasks`** + **`tool:github`** — two tools, merged and sorted by date. For each: if `pm_tool_defined <name>` is false, omit its lines and note "tool:<name> not defined — no due dates from it". Else pull forward-looking due dates from each tool's provider — `tool:tasks` from `$TASKS_SCOPE` (its tracker project), `tool:github` from `$GITHUB_SCOPE` (`owner/repo` issues/PRs with a due/milestone date).

If a tool's ref is blank, leave its lines as a TODO and still preserve Manual. **Run the read-modify-write under a lock** so concurrent tabs can't clobber each other's regeneration; write to a temp file and atomic-`mv` into place so a reader never sees a half-rewritten file:

  ```bash
  source "{{framework_root}}/lib/with-lock.sh"
  regen_calendar() {
    MARKER='<!-- PM:MANUAL'
    # preserved="$(sed -n "/$MARKER/,\$p" "$ROOT/CALENDAR.md")"   # marker line onward, kept verbatim
    # rebuild the Synced section (Upcoming events + Due dates sub-sections) above the marker from
    # tool:calendar / tool:tasks / tool:github (each guarded by pm_tool_defined), re-emit
    # "$preserved" unchanged below it, then atomic-mv the temp file over "$ROOT/CALENDAR.md".
  }
  mkdir -p "$ROOT/.pm"
  with_lock "$ROOT/.pm/.calendar.lock" regen_calendar
  ```
  - _related: `pm_tool_skills tasks` / `pm_tool_skills github` (discovery hints only)._

### Step 5 — Read handoff + open work

Read, in order: `<root>/LAST-SESSION.md` (where I left off — lead with this), `<root>/CONTEXT.md` (stable overview).

`LAST-SESSION.md` holds **one block per session** (`<!-- PM:SESSION <id> START -->`). Lead with **this session's own block** if present (`$SID` from Step 1), else the most recent. Surface other sessions' blocks briefly as "other recent sessions on this project" so concurrent work is visible.

```bash
awk -v s="<!-- PM:SESSION $SID START -->" -v e="<!-- PM:SESSION $SID END -->" \
  '$0==s{f=1;next} $0==e{f=0} f' "$ROOT/LAST-SESSION.md"
grep -oE 'PM:SESSION [^ ]+ START' "$ROOT/LAST-SESSION.md" | grep -v " $SID " || true
```

Then pull open work (each bullet guarded by `pm_tool_defined <name>`; omit with a note when undefined):

- **`tool:todo`** — open tasks for this project from its configured provider, filtered by `$TODO_SCOPE`. Undefined ⇒ "tool:todo not defined — tasks tracked manually in CONTEXT/notes".
- **`tool:tasks`** — open issues in `$TASKS_SCOPE` (the same tool that fed CALENDAR due dates, here for the open-work list).
- **`tool:github`** — open PRs / issues for `$GITHUB_SCOPE`.
- **`tool:logs`** — recent log entries matching `$KEYWORDS` (last few days) for recent decisions/actions; read the log store under `pm_tool_root_or_notes logs` (or use the provider's search skill, see `pm_tool_skills logs`).

### Step 6 — Print the briefing

Print these sections in order (omit a section when its tool is undefined, with a one-line note that it was skipped). Where a section is fed by a tool, append a one-line **related-skills** hint from `pm_tool_skills <name>` (discovery only — slash commands can't be auto-invoked):

- **Status & recent decisions** — from recent `tool:logs` entries + `tool:tasks` state
- **Open tasks / next actions** — `tool:todo` + `tool:tasks` + `tool:github` open items
- **Inbox needing a response** — action items / commitments / threads from `tool:email` (omit when undefined)
- **Upcoming** — `CALENDAR.md` (events from `tool:calendar`; due dates from `tool:tasks` + `tool:github`)
- **Recent meetings** — last few pointers from `meetings.jsonl` — _related: `pm_tool_skills meetings`_
- **Focus today** — your synthesis (lead from LAST-SESSION next-up)
- **Collaborators** — a quick-reference table from `$COLLABORATORS` (`config.collaborators`): **Name | Role | Slack | GitHub**. Render `slack` as the profile link and `github` as `@<username>`; leave a cell blank when the field is `""`. If the array is absent or empty, print `_(no collaborators configured — TODO)_` — do not fabricate people or handles. This is read from local config (no live/MCP call).
- **Quick links** — tracker project URL, repos, key docs from `CONTEXT.md`

### Step 7 — Log it — `tool:logs`

- **If `pm_tool_defined logs` is false:** skip with a note.
- **Else:** record via the `logs` tool's configured provider an action entry like: `pm-start: opened '<name>' — synced N new meetings, regenerated CALENDAR, briefed`.

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
- **Session id: prefer the harness UUID, mint only as a fallback.** When `session.sh` returns a real UUID (from `CLAUDE_CODE_SESSION_ID` etc.), use it verbatim — never mint. Only when it returns a WEAK id (`tty-…`/`shell-…`) does pm-start mint a UUID and persist it to `{{framework_root}}/sessions/.mint/<anchor>`; this is the ONLY skill that writes the mint file. `session.sh` (used by `/pm-status` and `/pm-end`) only ever READS it, so all three resolve the same id.
- **Meeting catch-up runs inline** — never delegate the meeting fetch to a subagent (MCP can fail silently there).
- **Every tool is guarded by `pm_tool_defined <name>`** — when a tool is undefined, skip its sync and print "tool:<name> not defined — skipping <capability>" (naming the tool's manual skill where useful). Never fabricate data for an undefined tool.
- **CALENDAR regeneration preserves manual entries** below the `<!-- PM:MANUAL -->` marker. Never drop them.
- **meetings.jsonl is pointers only** — dedupe by `meeting_id`, never copy transcript bodies into the project.
- **Blank config values are TODOs**, surfaced in the briefing, not fabricated.
- **No commit/push.**

## Signal Keywords
<!-- Comma-separated terms the skills collector uses to attribute learnings to this skill -->
pm-start, pm-framework, project-briefing, morning-brief, live-sync, meeting-sync, calendar-regen, session-marker, pick-up-where-left-off, project-manager
