# pm-start — LIVE sync steps (companion doc)

> Rendered by `/pm-generate` alongside `pm-start/SKILL.md`. Only `{{framework_root}}` and
> `{{notes_root}}` are substituted at render time.

**Read this file ONLY on a COMPLETE run** — that is, when `SKIP_SYNC=0` (no same-day stamp,
or `--full` / `--force` was passed). `SKILL.md` Step 1 decides; it does not defer here on a
same-day re-brief. Every step below is unconditionally live, so there is deliberately no
`SKIP_SYNC` branch in this file: reaching it at all means the live sync is running.

All shell variables referenced here (`$ROOT`, `$MEETINGS_SCOPE`, `$EMAIL_SCOPE`,
`$CALENDAR_SCOPE`, `$TASKS_SCOPE`, `$GITHUB_SCOPE`, `$KEYWORDS`) were set in `SKILL.md`
Step 1, and `pm_load_config` has already been sourced.

---

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
- **Else:** pull this project's action items / commitments / threads needing a response from the `email` tool's configured provider, filtered by `$EMAIL_SCOPE` (the project's label/folder/sender filter), falling back to keyword subject match against `$KEYWORDS` when `$EMAIL_SCOPE` is blank. **Run inline in the main session — MCP-backed mail tools can fail silently inside subagents.** Surface the results in the briefing (`SKILL.md` Step 6); do not write them to a project file. If `$EMAIL_SCOPE` is blank, note it as a TODO.

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

---

When these four steps are done, return to `SKILL.md` and continue at **Step 5**.
