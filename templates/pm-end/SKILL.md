---
name: pm-end
description: End-of-session capture for the active PM project — runs the logs-sweep + todo-hygiene guard first (each half guarded by its own tool), summarizes the session, writes a tagged note, and updates this session's block in LAST-SESSION.md (current state / open threads / next-up / blockers) without clobbering other sessions' blocks. Use when wrapping up work on a project, "/pm-end", or "I'm done for now".
---

# pm-end — Capture & Hand Off (EOD)

> Rendered by `/pm-generate`. This skill addresses capabilities by **named tool**
> (`tool:<name>`) and resolves each at runtime via `{{framework_root}}/lib/config.sh` —
> only `{{framework_root}}` and `{{notes_root}}` are substituted at render time. An
> undefined tool (provider `none`) degrades with a printed note. The handoff, commit, and
> auto-ship logic is tool-agnostic and never depends on the registry.

## Default tool names

The framework imposes no fixed role vocabulary — your tools are whatever names
`~/.config/pm/config.json` declares. This skill references the **default name set
`/pm-generate` suggests**: `meetings`, `calendar`, `email`, `tasks`, `github`, `todo`,
`logs`, `notes`. pm-end only touches `tool:logs` (guard + session summary) and `tool:todo`
(guard + journal). If you renamed a tool, adjust the `tool:<name>` references below.

## Trigger

**Use when:** wrapping up a work session on the active project — "I'm done", "wrap up", "/pm-end". Captures state so the next `/pm-start` can lead with it.
**Do NOT use when:** opening the session → `/pm-start`. A quick mid-session recap → `/pm-status`.
**Inputs expected:** none — resolves the project from the per-session marker.
**Outputs produced:** backfilled logger entries (the guard, if a logger is configured); a tagged note (if logger/notes support it); an updated `<root>/LAST-SESSION.md` block for this session; and (when the project is in a git repo) a commit of the project folder on this session's own branch `chore/<day>-<slug>-pm-<shortsid>` — left local by default, or (when `.pm/config.json` sets `auto_ship: true`) pushed and merged via a PR against the repo's default base branch.

## Related Skills

- [`pm-start`](../pm-start/SKILL.md) — opens the next session, reads the `LAST-SESSION.md` this skill writes
- [`pm-status`](../pm-status/SKILL.md) — cache-only mid-session briefing

---

## Framework facts (shared across all four pm-* skills)

- **Per-session marker:** `{{framework_root}}/sessions/<session-id>` holds the active project root (`<session-id>` via `{{framework_root}}/lib/session.sh`). **This skill reads it** (does not write it).
- **Named tools:** `{{framework_root}}/lib/config.sh` (`pm_load_config`) exposes the tool registry; the guard + capture branch on `pm_tool_defined logs` + `pm_tool_defined todo`. Per-project scoping lives in `.pm/config.json` → `.tool_refs.<name>`. For Jamie's setup `logs`→clog and `todo`→crrt.
- **Per-project files** (in `<root>`): `.pm/config.json`, `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`, `LAST-SESSION.md`.
- **History lives in `tool:logs`; narrative in the `tool:todo` journal; the handoff lives in `LAST-SESSION.md`.** There is **no JOURNAL.md** — `LAST-SESSION.md` carries one block per session (a forward handoff, not a log).
- **Collaborators roster (`.pm/config.json` → `collaborators`):** a hand-maintained array (`{name, role, slack, github, email}`) `/pm-start` renders as a quick-reference. A local lookup index agents read to resolve teammates without an MCP call; absent/empty = TODO.

## Steps

### Step 1 — Resolve the project from the marker

```bash
source "{{framework_root}}/lib/config.sh"
pm_load_config || { echo "pm: no config — run /pm-generate first."; exit 1; }
SID=$("{{framework_root}}/lib/session.sh")        # same resolver pm-start used to write the marker
ROOT="$(cat "{{framework_root}}/sessions/$SID" 2>/dev/null)"
test -f "$ROOT/.pm/config.json" || { echo "No active PM project this session — run /pm-start @<path> first."; exit 1; }
NAME=$(jq -r '.name' "$ROOT/.pm/config.json")
TODO_SCOPE=$(jq -r '.tool_refs.todo // ""' "$ROOT/.pm/config.json")   # crrt tag for this project
KEYWORDS=$(jq -r '.keywords | join(" ")' "$ROOT/.pm/config.json")
```

### Step 2 — GUARD (mandatory, always first action of substance)

**Same guard as `/pm-status`.** Both halves guarded independently:

1. **`tool:logs` sweep** — **if `pm_tool_defined logs` is false:** skip and print "tool:logs not defined — skipping hygiene sweep." **Else:** invoke the `logs` provider's backfill sweep — for Jamie's `clog`, run [`clog-sweep`](../clog-sweep/SKILL.md) ("clog it"): scan the session for unlogged state-changes and auto-write the missing entries with paired LEARNINGs. _related: `pm_tool_skills logs`._
2. **`tool:todo` hygiene** — **if `pm_tool_defined todo` is false:** skip and print "tool:todo not defined — skipping task hygiene." **Else:** update the `todo` provider (Jamie: `crrt`) — complete tasks finished this session, add new tasks surfaced, set due dates where known. Tag new tasks with `$TODO_SCOPE`.

### Step 3 — Summarize the session's log for this project — `tool:logs`

- **If `pm_tool_defined logs` is false:** summarize from your own memory of the session (what got done, decisions, anything left open) and note "tool:logs not defined — summary from session memory only". This summary feeds Steps 4 and 5.
- **Else:** read today's entries from the `logs` provider (Jamie: `clog`) and filter to this project (`$TODO_SCOPE` / `$KEYWORDS`). Resolve the log directory from clog's own config (robust if logs are relocated):

  ```bash
  CLOG_CFG="$HOME/.config/clog/config.yaml"
  LOG_ROOT=$(grep '^log_root:' "$CLOG_CFG" 2>/dev/null | cut -d'"' -f2); LOG_ROOT="${LOG_ROOT/\$\{HOME\}/$HOME}"
  LOG_SUBDIR=$(grep '^log_subdir:' "$CLOG_CFG" 2>/dev/null | cut -d'"' -f2)
  TODAY_LOG="${LOG_ROOT:-$(pm_tool_root_or_notes logs)}/${LOG_SUBDIR:-claude}/$(date +%Y%m%d).jsonl"
  ```

  Produce a short summary from `$TODAY_LOG`: what got done, decisions made, anything left open.

### Step 4 — Write a tagged journal entry — `tool:todo`

- **If `pm_tool_defined todo` is false:** skip with a note — there is no journal sink. (The `LAST-SESSION.md` block in Step 5 is the durable record.)
- **Else:** record a one-line journal note via the `todo` provider (Jamie: `crrt`), tagged with `$TODO_SCOPE`:

  ```bash
  crrt note "pm-end ${NAME}: <one-line summary of the session> #${TODO_SCOPE}"
  ```

  Keep it one line (per crrt house style). Add a second one-line note only for a distinct learning or follow-up. _related: `pm_tool_skills todo`._

### Step 5 — Update this session's handoff block in LAST-SESSION.md

`LAST-SESSION.md` holds **one block per session** so two sessions on the same project never clobber each other's handoff. Write **only this session's** block via the helper — it replaces this session's block, preserves all other sessions' blocks, and wraps any legacy single-handoff file as a `legacy` block on first run. `$SID` was resolved in Step 1.

Pipe the block body in on stdin (the helper adds the `## Session <id> — <timestamp>` heading, so use `###` subsections in the body):

```bash
"{{framework_root}}/lib/handoff-write.sh" --root "$ROOT" --session "$SID" --name "$NAME" << 'EOF'
### Current state
- <where things stand now>

### Open threads
- <in-flight items, half-done work>

### Next up
- <the first things to pick up next session>

### Blockers
- <anything waiting on someone / something, or "none">
EOF
```

### Step 6 — Commit the session's changes (optional)

If the project folder is inside a git repo, land the session's work on **this session's own branch** `chore/<day>-<slug>-pm-<shortsid>` — never push directly to `main`. Each tab commits to a **distinct per-session branch** (keyed by a short, ref-safe form of `$SID`), so concurrent tabs never race on the same ref or index. The helper does all of this: it **stages ONLY the project folder (`$REL/`)**, skips the commit when there is nothing to commit (no empty commit), and — because the working tree is shared across tabs — **captures the branch you were on and restores it afterward** so another tab isn't left checked out on this tab's pm branch. If the project is not in a git repo, it prints a notice and skips. `$SID` and `$NAME` were resolved in Step 1.

**This local commit runs in BOTH modes.** What happens *after* it depends on the per-project `auto_ship` flag in `.pm/config.json` (default `false`).

```bash
AUTO_SHIP=$(jq -r '.auto_ship // false' "$ROOT/.pm/config.json")
BRANCH=$("{{framework_root}}/lib/session-commit.sh" --root "$ROOT" --session "$SID" --name "$NAME")
```

Only paths under `$ROOT` are ever staged; unrelated dirty files outside the project folder stay unstaged and travel with the checkout (no stashing). If the commit-message hook rejects the message, fix the message — never bypass hooks (never `--no-verify`).

#### Mode A — `auto_ship=false` (default): stop after the local commit

The default. Leave the per-session branch local and **do not** push or open a PR. Because each tab produces its own `chore/<day>-<slug>-pm-<shortsid>` branch, reconcile them at end of day into a single branch (or one PR per day) and delete the merged session branches. This is **advisory** — in this mode `/pm-end` never auto-merges or auto-pushes (matches the "never push to `main`" rule and the "never bypass hooks" note above).

```bash
DAY=$(date +%Y-%m-%d); SLUG=$(printf '%s' "$NAME" | tr '[:upper:] ' '[:lower:]-')
REPO=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)
# List today's per-session pm branches:
git -C "$REPO" branch --list "chore/$DAY-$SLUG-pm-*"
# Merge them onto a single day branch, then delete the merged ones:
git -C "$REPO" checkout -b "chore/$DAY-$SLUG-pm" 2>/dev/null || git -C "$REPO" checkout "chore/$DAY-$SLUG-pm"
#   ... git merge each session branch ...   (their commit messages already conform)
#   ... then: git branch -d chore/$DAY-$SLUG-pm-<shortsid>   (the branch-cleanup skill can help)
```

#### Mode B — `auto_ship=true`: auto-ship the session branch via a PR

Opt-in per project (`"auto_ship": true` in `.pm/config.json`). After the local commit, ship the per-session branch **through the PR workflow** — push the branch, open a PR against the repo's default base branch, then merge it and delete the branch. It **never pushes `main` directly** and **never bypasses hooks**. `session-commit.sh` itself stays pure-git; this ship logic lives here.

Guards (all must hold, else this silently no-ops and Mode A's advisory applies):

- **A commit actually happened** — `session-commit.sh` skips the commit when nothing changed, so ship only if the branch is ahead of the base.
- **A git remote exists** — no `origin`, nothing to ship.
- **Never target/push `main`** — only the per-session branch is pushed; `main` is updated solely by the PR merge.

```bash
if [[ "$AUTO_SHIP" == "true" && -n "$BRANCH" ]]; then
  REPO=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)
  # Default base branch (main/master) from origin's HEAD; fall back to main.
  BASE=$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  BASE="${BASE:-main}"
  if git -C "$REPO" remote get-url origin >/dev/null 2>&1 \
     && [[ -n "$(git -C "$REPO" rev-list "$BASE..$BRANCH" 2>/dev/null)" ]]; then
    git -C "$REPO" push -u origin "$BRANCH"                 # push the SESSION branch — never main
    ( cd "$REPO" && gh pr create --base "$BASE" --head "$BRANCH" \
        --title "docs(pm): $(printf '%s' "$NAME" | tr '[:upper:] ' '[:lower:]-') session $(date +%Y-%m-%d)" \
        --body "Automated /pm-end session ship for $NAME." )
    ( cd "$REPO" && gh pr merge "$BRANCH" --merge --delete-branch )   # merge via PR, delete the branch
  else
    echo "auto_ship: nothing to ship (no commit, or no origin remote) — skipping."
  fi
fi
```

### Step 7 — Log it — `tool:logs`

- **If `pm_tool_defined logs` is false:** skip with a note.
- **Else:** record via the `logs` provider (Jamie: `clog`): `clog ACTION "pm-end: wrapped '<name>' — journal logged, LAST-SESSION.md updated"`.

### Step 8 — Release the session color (optional)

If `/pm-start` set a session color, print a paste-ready line to reset the prompt bar. The conversation name stays (set via `/rename`); only the color is cleared:

```
/color default
```

Print this only when the project has a `session_color` configured; skip it otherwise.

## Rules

- **The guard always runs first** (`tool:logs` sweep + `tool:todo` hygiene, each guarded by `pm_tool_defined`) — identical to `/pm-status`. When a guard tool is undefined, skip that half and say so. Non-negotiable.
- **LAST-SESSION.md is per-session blocks** — write only *your* session's block via `handoff-write.sh` (it replaces your block, preserves others). Never overwrite the whole file: a concurrent session on the same project may own another block.
- **No JOURNAL.md** — do not create one.
- **Every tool is guarded by `pm_tool_defined <name>`** — never fabricate `tool:logs` or `tool:todo` activity for an undefined tool; print "tool:<name> not defined — skipping <capability>".
- **Commit (when in a repo) is scoped to the project folder** — stage only paths under `$ROOT`, on **this session's own branch** `chore/<day>-<slug>-pm-<shortsid>` (never the shared per-day branch); the shared working tree is restored to the branch you were on afterward; never push to `main`, never stage files outside the project folder. Reconcile the per-session branches at end of day (see Step 6).
- **`auto_ship` (per-project, `.pm/config.json`, default `false`)** — when `false`, the session branch stays local and you reconcile at EOD (Mode A). When `true`, `/pm-end` auto-ships the branch via the PR workflow (push branch → `gh pr create` → `gh pr merge --merge --delete-branch`), only when a commit was actually made and a remote exists — never a direct push to `main`, never `--no-verify` (Mode B).

## Signal Keywords
<!-- Comma-separated terms the skills collector uses to attribute learnings to this skill -->
pm-end, pm-framework, eod-wrap, session-capture, last-session, handoff, hygiene-guard, project-manager
