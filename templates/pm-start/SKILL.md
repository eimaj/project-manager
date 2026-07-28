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
**Inputs expected:** `@<path>` to the project root on first run in a session (sets the marker). Subsequent commands in the same session read the marker. **`@<path>` is optional** — with no marker and no path, pm-start resolves the project from the current directory, else from the single project open in another live pane, and asks when that is ambiguous. Optional `--full` (alias `--force`) anywhere in the args forces a complete live re-sync even if one already ran today.
**Same-day re-run:** if a COMPLETE run already happened today for this project (per-project stamp `<root>/.pm/.last-start`), pm-start skips the repeating LIVE sync and just re-briefs from cache (like `/pm-status`), reporting how old the data is (`synced 5h 04m ago`) — pass `--full` to override. On this path the companion `live-sync.md` is never opened.
**Outputs produced:** session marker `{{framework_root}}/sessions/<session-id>`; new meeting pointers appended to `<root>/meetings.jsonl`; regenerated `<root>/CALENDAR.md`; a printed briefing; a same-day daily stamp `<root>/.pm/.last-start` (COMPLETE runs only); and a paste-ready `/rename` + `/color` block.

## Related Skills

- [`pm-init`](../pm-init/SKILL.md) — one-time scaffold (run before the first `/pm-start`)
- [`pm-status`](../pm-status/SKILL.md) — cache-only rerunnable briefing. **The same-day-skip path delegates to this behavior** — it reads the same cached project files and prints the same briefing, minus the guard. Do not re-implement its cache-read here.
- [`pm-end`](../pm-end/SKILL.md) — EOD capture

---

## Framework facts (shared across all four pm-* skills)

- **Project identity = its folder root path.** Registry: `{{framework_root}}/registry.jsonl` (deduped by `root`).
- **Per-session marker:** `{{framework_root}}/sessions/<session-id>` holds the active project root path, where `<session-id>` comes from `{{framework_root}}/lib/session.sh`. **This skill writes it.** Concurrent sessions each hold their own.
- **Named tools, resolved at runtime.** `lib/config.sh` (`pm_load_config`) exposes the tool registry; each step branches on `pm_tool_defined <name>` and degrades with a note when a tool is undefined. Each tool's concrete backend is its **configured provider** (`pm_tool_provider <name>`) — the skills never hard-code one. Per-project scoping for a tool lives in `.pm/config.json` → `.tool_refs.<name>` (how THIS project is identified inside that tool's backend).
- **Per-project files** (in `<root>`): `.pm/config.json`, `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`, `LAST-SESSION.md`, `reports/`, `briefs/`.
- **Project-local reports vs a tool's global root.** A project's OWN report artifacts live under **`<root>/reports/`** (seeded by `/pm-init`). This is distinct from a tool's **global** `root` (`pm_tool_root <name>` — the shared, cross-project sink such as a meeting archive or log store). When a pm-* skill writes a report/output **for the active project**, target `<root>/reports/`; a tool's `root` / `pm_tool_root_or_notes <name>` is for that tool's cross-project archive.
- **Project-local briefs.** A project's `/orchestrate-brief` output lives under its **`briefs_dir`** (`.pm/config.json`, default **`<root>/briefs/`**, seeded by `/pm-init`), named `YYYY-MM-DD-<TICKET>-<slug>.md` — a per-project artifact dir like `<root>/reports/`. `/orchestrate-brief` produces `brief.md` at the orchestrate default `{artifact_root}/runs/<session_id>/`; resolve `briefs_dir` and relocate it there (`mkdir -p` + `mv`) — confirm the destination when interactive, move silently in automated runs — then pass the new path to `/orchestrate`. **Commit the relocated brief** — briefs live untracked in the project tree and a concurrent session can wipe an uncommitted one. Never modify orchestrate's global `artifact_root`.
- **Per-project tool override.** `.pm/config.json` MAY carry an optional `tools{}` block; after `pm_load_project <root>` the accessors resolve the **effective** tool = project override ?? global registry (per field), scoped to this project only — it never mutates the global `~/.config/pm/config.json`. Precedence: project override > global > undefined (degrade).
- **Meetings = pointers, not copies.** The meeting archive lives under `pm_tool_root_or_notes meetings` (the `meetings` tool's configured `root`, falling back to `$PM_NOTES_ROOT` when it has no explicit `root`). The project's `meetings.jsonl` holds only pointers `{meeting_id, date, title, path}`.
- **Collaborators roster (`.pm/config.json` → `collaborators`):** a hand-maintained array (`{name, role, slack, github, email}`) this skill renders as a quick-reference (Step 6). A local lookup index read from config — no live/MCP call at read time. Absent/empty = TODO.

## Steps

### Step 1 — Resolve the project and write the session marker

```bash
# Load the tool registry (accessors + framework paths) — required for every later step.
source "{{framework_root}}/lib/config.sh"
pm_load_config || { echo "pm: no config — run /pm-generate first."; exit 1; }

# Parse invocation args: split the project @<path> from the --full/--force override token
# so the flag is never mistaken for the path. FULL=1 forces the COMPLETE flow (all steps live).
FULL=0; ARG_PATH=""
for tok in "$@"; do
  case "$tok" in
    --full|--force) FULL=1 ;;
    @*)             ARG_PATH="${tok#@}" ;;    # @path → path
    *)              ARG_PATH="${ARG_PATH:-$tok}" ;;  # tolerate a bare path
  esac
done

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
# If the user passed @<path> (parsed into $ARG_PATH above), that is the root. Else read the marker:
ROOT="${ARG_PATH:-$(cat "$MARKER" 2>/dev/null)}"

# --- Discovery: no @path given AND no marker for this session ------------------------
# A second pane opening a project another pane already has open should not have to retype
# the path. Resolve it, in order: (1) cwd sits inside a registered project, (2) exactly one
# project is open in a LIVE pane. Ambiguity is never guessed — it is listed and asked.
if [[ -z "$ROOT" ]]; then
  REG="{{framework_root}}/registry.jsonl"
  # (1) cwd — the DEEPEST registered root that is $PWD or an ancestor of it (nested projects).
  ROOT="$(jq -r '.root // empty' "$REG" 2>/dev/null | while IFS= read -r r; do
            [[ -n "$r" && ( "$PWD" == "$r" || "$PWD" == "$r"/* ) ]] && printf '%s\t%s\n' "${#r}" "$r"
          done | sort -rn | head -1 | cut -f2)"
  if [[ -n "$ROOT" ]]; then
    echo "pm: no @path given — resolved '$ROOT' from the current directory."
  else
    # (2) sibling panes. A marker alone proves nothing (they are immortal until pruned), so
    # require a LIVE session: a Claude Code transcript for that sid touched in the last 24h.
    SESS="{{framework_root}}/sessions"; CCP="${PM_CC_PROJECTS:-$HOME/.claude/projects}"
    LIVE_ROOTS="$(find "$SESS" -maxdepth 1 -type f -print 2>/dev/null | while IFS= read -r m; do
        sid="$(basename "$m")"
        [[ -n "$(find "$CCP" -maxdepth 2 -name "$sid.jsonl" -mmin -1440 -print -quit 2>/dev/null)" ]] \
          && cat "$m" 2>/dev/null
      done | sed '/^$/d' | sort -u)"
    N="$(printf '%s' "$LIVE_ROOTS" | grep -c . || true)"
    if [[ "$N" -eq 1 ]]; then
      ROOT="$LIVE_ROOTS"
      echo "pm: no @path given — opening '$ROOT' (already open in another live pane)."
    elif [[ "$N" -gt 1 ]]; then
      echo "pm: $N projects are open in other panes — name the one you want:"
      printf '%s\n' "$LIVE_ROOTS" | sed 's#^#  /pm-start @#'
      exit 1
    fi
  fi
fi

# ABSOLUTIZE before validating or writing. A relative `@logs/Foo` validates fine here —
# cwd happens to be right at this moment — but it lands in the marker verbatim, and every
# later /pm-status / /pm-end runs from a different cwd and cannot resolve it. A marker must
# always hold an absolute path.
if [[ -n "$ROOT" && "$ROOT" != /* ]]; then
  ROOT="$(cd -P "$ROOT" 2>/dev/null && pwd)" || ROOT=""
fi
test -f "$ROOT/.pm/config.json" || { echo "Not a PM project (run /pm-init): $ROOT"; exit 1; }
mkdir -p "{{framework_root}}/sessions"
printf '%s\n' "$ROOT" > "$MARKER"
# Reopening clears any "closed" flag a previous /pm-end in THIS pane dropped, so sibling
# panes list us as live again. Harmless when no flag exists.
rm -f "{{framework_root}}/sessions/.closed/$SID"
```

> **Why mint?** `session.sh` is a pure reader — with no harness session var (`CLAUDE_CODE_SESSION_ID` / `CLAUDE_SESSION_ID` / `PM_SESSION_PID` / `TERM_SESSION_ID`) it can only return a weak `tty-…`/`shell-$PPID` id, which collapses distinct sessions together. pm-start (the one skill that owns session-marker creation) mints a stable UUID once and persists it keyed by the shell's anchor (`{{framework_root}}/sessions/.mint/<anchor>`). Every later `session.sh` call in the same shell rediscovers it via its read-only mint lookup, so `/pm-status` and `/pm-end` resolve the identical id. When a real harness UUID is present, it is used directly and nothing is minted.

Load config into shell vars for later steps:

```bash
# Per-project tool refs — how THIS project is identified inside each tool's backend.
# A blank ref => that tool falls back to keyword matching against $KEYWORDS.
#
# ONE jq pass, not nine: fields are emitted in a fixed order, one per line, and read back
# positionally (a blank field is an empty line). Keep the emit order and the read order in
# lockstep when adding a field. Assumes no config value contains a newline.
{
  IFS= read -r MEETINGS_SCOPE   # e.g. a meetings-provider folder
  IFS= read -r CALENDAR_SCOPE   # e.g. calendar/category filter
  IFS= read -r EMAIL_SCOPE      # e.g. an email label/folder
  IFS= read -r TASKS_SCOPE      # e.g. a tracker project
  IFS= read -r GITHUB_SCOPE     # e.g. owner/repo
  IFS= read -r TODO_SCOPE       # e.g. a todo tag/list
  IFS= read -r KEYWORDS
  IFS= read -r NAME
  IFS= read -r SESSION_COLOR
  IFS= read -r COLLABORATORS    # roster for the Step 6 quick-reference (compact JSON)
} < <(jq -r '
  .tool_refs.meetings // "",
  .tool_refs.calendar // "",
  .tool_refs.email    // "",
  .tool_refs.tasks    // "",
  .tool_refs.github   // "",
  .tool_refs.todo     // "",
  ((.keywords      // []) | join(" ")),
  .name          // "",
  .session_color // "",
  ((.collaborators // []) | tojson)
' "$ROOT/.pm/config.json")
```

Decide whether the repeating LIVE sync runs, or this is a same-day re-brief. Detection is **per-project** (keyed by `$ROOT`), independent of session id — multiple sessions in a day share one stamp:

```bash
# --- Same-day "already ran today" detection ---
# Stamp <root>/.pm/.last-start stores the date+time of the last COMPLETE (full-sync) run.
# Already-ran-today = stamp exists AND its stored date equals today's runtime date.
STAMP="$ROOT/.pm/.last-start"
TODAY="$(date +%F)"                                   # runtime date — never hardcode
SKIP_SYNC=0; SYNC_AGE=""
if [[ "$FULL" -eq 0 && -r "$STAMP" ]]; then
  LAST_DAY="$(cut -d' ' -f1 "$STAMP" 2>/dev/null)"    # stored as "YYYY-MM-DD HH:MM"
  LAST_TIME="$(cut -d' ' -f2 "$STAMP" 2>/dev/null)"
  if [[ "$LAST_DAY" == "$TODAY" ]]; then
    SKIP_SYNC=1
    # Report the AGE of the data, not just that a run happened. "already ran today (10:56)"
    # buries the fact that a 16:00 pane is briefing on five-hour-old data; meetings, PRs and
    # mail from the afternoon are simply absent. State the staleness up front.
    STAMP_EPOCH="$(date -j -f '%Y-%m-%d %H:%M' "$LAST_DAY $LAST_TIME" +%s 2>/dev/null \
                   || date -d "$LAST_DAY $LAST_TIME" +%s 2>/dev/null)"
    if [[ -n "$STAMP_EPOCH" ]]; then
      AGE_MIN=$(( ( $(date +%s) - STAMP_EPOCH ) / 60 ))
      (( AGE_MIN < 0 )) && AGE_MIN=0
      SYNC_AGE="$(printf '%dh %02dm' $((AGE_MIN/60)) $((AGE_MIN%60)))"
    fi
    echo "pm: synced ${SYNC_AGE:-earlier today} ago (${LAST_TIME:-$LAST_DAY}) — skipping live sync. /pm-start --full to re-sync."
  fi
fi
# SKIP_SYNC=1 → skip Steps 2, 3, 3b, 4 and the LIVE pulls in Step 5; still run the LOCAL
# reads in Step 5 and Steps 6–8. FULL=1 (or no same-day stamp) → COMPLETE flow, all steps live.
```

(Session branding — `/rename` + `/color` — is printed at the end in Step 8 for the user to paste; slash commands can't be invoked programmatically.)

### Steps 2–4 — LIVE sync (COMPLETE runs only) — see `live-sync.md`

These four steps (meeting catch-up, meeting-pointer append, inbox scan, CALENDAR regen) are
the only network-bound work in this skill, and a same-day re-brief skips all of them. They
live in the companion doc [`live-sync.md`](./live-sync.md) so this file stays small: the
model reads roughly 16 KB of live-sync prose only on the runs that actually execute it.

- **If `SKIP_SYNC=1` (already ran today):** **do not open `live-sync.md`.** Skip straight to
  Step 5 — the earlier COMPLETE run did this work, and Step 6 re-briefs from the cached
  files it produced (`meetings.jsonl`, `CALENDAR.md`).
- **If `SKIP_SYNC=0` (COMPLETE run):** read `live-sync.md` now and execute Steps 2, 3, 3b
  and 4 exactly as written there, then return here and continue at Step 5.

### Step 5 — Read handoff + open work

Read, in order: `<root>/LAST-SESSION.md` (where I left off — lead with this), `<root>/CONTEXT.md` (stable overview).

`LAST-SESSION.md` holds **one block per session** (`<!-- PM:SESSION <id> START -->`). Lead with **this session's own block** if present (`$SID` from Step 1), else the most recent. Surface other sessions' blocks briefly as "other recent sessions on this project" so concurrent work is visible.

```bash
awk -v s="<!-- PM:SESSION $SID START -->" -v e="<!-- PM:SESSION $SID END -->" \
  '$0==s{f=1;next} $0==e{f=0} f' "$ROOT/LAST-SESSION.md"
grep -oE 'PM:SESSION [^ ]+ START' "$ROOT/LAST-SESSION.md" | grep -v " $SID " || true
```

These two LOCAL handoff reads always run — even on a same-day re-brief (they are cheap, cached files).

**Then surface the panes working on this project RIGHT NOW.** `LAST-SESSION.md` blocks are written by `/pm-end`, so they only ever show *finished* sessions — a pane that has been running since 09:00 is invisible in them all day. This is the live view:

```bash
"{{framework_root}}/lib/active-panes.sh" --root "$ROOT"
```

Print the result as **"Other panes on this project now"** (session id short-form, idle time, when it opened), or omit the section entirely when there are none. This read always runs — it is local and cheap, and it is *most* valuable on a same-day re-brief, which is exactly when siblings are likely active.

- **If `pm_tool_defined logs`:** for each sid listed, pull that session's recent entries for this project from the `logs` tool's configured provider (most loggers record a session id; filter on it) and summarize each pane in one line — what it has been doing. Undefined ⇒ list the panes without activity detail. Never fabricate what another pane is doing; if the logger cannot filter by session, say so and list panes only.

Then pull open work from the LIVE trackers. **If `SKIP_SYNC=1` (already ran today):** skip this pull entirely — do not hit `tool:todo` / `tool:tasks` / `tool:github` / `tool:logs` live; the Step 6 briefing surfaces open work from the cached files instead (mirroring `/pm-status`). On a COMPLETE run, pull each bullet (guarded by `pm_tool_defined <name>`; omit with a note when undefined):

- **`tool:todo`** — open tasks for this project from its configured provider, filtered by `$TODO_SCOPE`. Undefined ⇒ "tool:todo not defined — tasks tracked manually in CONTEXT/notes".
- **`tool:tasks`** — open issues in `$TASKS_SCOPE` (the same tool that fed CALENDAR due dates, here for the open-work list).
- **`tool:github`** — open PRs / issues for `$GITHUB_SCOPE`.
- **`tool:logs`** — recent log entries matching `$KEYWORDS` (last few days) for recent decisions/actions; read the log store under `pm_tool_root_or_notes logs` (or use the provider's search skill, see `pm_tool_skills logs`).

### Step 6 — Print the briefing

Always runs (both COMPLETE and same-day re-brief). **On a same-day re-brief (`SKIP_SYNC=1`) this is exactly the cache-only briefing `/pm-status` prints** — synthesize from the cached files (`LAST-SESSION.md`, `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`) and skip any section whose data comes only from a LIVE pull that did not run (e.g. the fresh inbox). Do not re-implement pm-status's cache read — mirror it.

**On a same-day re-brief, open the briefing with the data's age** — `_Cached briefing — synced $SYNC_AGE ago. Meetings, PRs and mail since then are not reflected. `/pm-start --full` to re-sync._` A reader must not have to infer staleness from a skipped-step notice further up the transcript.

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
- **Else:** record via the `logs` tool's configured provider an action entry — matched to the run type:
  - COMPLETE run: `pm-start: opened '<name>' — synced N new meetings, regenerated CALENDAR, briefed`.
  - Same-day re-brief (`SKIP_SYNC=1`): `pm-start: re-opened '<name>' (same-day) — skipped live sync, re-briefed from cache`.

### Step 7b — Stamp the completed full sync — COMPLETE runs only

Record today's date + time as the last COMPLETE (full-sync) run, so a later same-day invocation detects it (Step 1) and re-briefs instead of re-syncing.

```bash
# Only a COMPLETE run writes the stamp. A skipped (cache-only) re-run deliberately does NOT
# touch it: the stored value must stay the date-of-last-FULL-sync so the "already ran today
# (HH:MM)" reference keeps pointing at the real last sync, not the last re-brief.
if [[ "$SKIP_SYNC" -eq 0 ]]; then
  mkdir -p "$ROOT/.pm"
  printf '%s %s\n' "$(date +%F)" "$(date +%H:%M)" > "$ROOT/.pm/.last-start"
fi
```

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
- **Same-day re-run skips the repeating LIVE sync.** Detection is per-project via `<root>/.pm/.last-start` (stored date == `date +%F` today), independent of session id. When already-ran-today, print the one-line notice, skip Steps 2/3/3b/4 and the Step 5 LIVE pulls, and re-brief from cache (mirroring `/pm-status`); still run Step 1 (marker), the Step 5 LOCAL reads, and Steps 6–8. `--full` (alias `--force`) anywhere in the args forces the COMPLETE flow. **Only a COMPLETE run writes/updates the stamp** — a skipped re-brief must not overwrite the date-of-last-full-sync.
- **Session id: prefer the harness UUID, mint only as a fallback.** When `session.sh` returns a real UUID (from `CLAUDE_CODE_SESSION_ID` etc.), use it verbatim — never mint. Only when it returns a WEAK id (`tty-…`/`shell-…`) does pm-start mint a UUID and persist it to `{{framework_root}}/sessions/.mint/<anchor>`; this is the ONLY skill that writes the mint file. `session.sh` (used by `/pm-status` and `/pm-end`) only ever READS it, so all three resolve the same id.
- **Discovery never guesses.** With no `@path` and no marker, resolve from cwd, then from projects open in LIVE panes (a marker alone is not evidence — markers outlive their sessions). Exactly one candidate ⇒ use it and say where it came from. More than one ⇒ list them and stop; do not pick.
- **The marker always holds an ABSOLUTE project root.** Absolutize `$ARG_PATH` before validating or writing it. A relative `@path` passes the validation check (cwd is right *now*) but every later `/pm-status` and `/pm-end` runs from a different cwd and cannot resolve it.
- **Meeting catch-up runs inline** — never delegate the meeting fetch to a subagent (MCP can fail silently there).
- **Every tool is guarded by `pm_tool_defined <name>`** — when a tool is undefined, skip its sync and print "tool:<name> not defined — skipping <capability>" (naming the tool's manual skill where useful). Never fabricate data for an undefined tool.
- **CALENDAR regeneration preserves manual entries** below the `<!-- PM:MANUAL -->` marker. Never drop them.
- **meetings.jsonl is pointers only** — dedupe by `meeting_id`, never copy transcript bodies into the project.
- **Blank config values are TODOs**, surfaced in the briefing, not fabricated.
- **No commit/push.**

## Signal Keywords
<!-- Comma-separated terms the skills collector uses to attribute learnings to this skill -->
pm-start, pm-framework, project-briefing, morning-brief, live-sync, meeting-sync, calendar-regen, session-marker, pick-up-where-left-off, project-manager, same-day-skip, --full, idempotent-rerun, daily-stamp
