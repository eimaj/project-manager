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
- **Named tools:** `{{framework_root}}/lib/config.sh` (`pm_load_config`) exposes the tool registry; the guard + capture branch on `pm_tool_defined logs` + `pm_tool_defined todo`. Each tool resolves to its configured provider via `pm_tool_provider <name>`. Per-project scoping lives in `.pm/config.json` → `.tool_refs.<name>`.
- **Per-project files** (in `<root>`): `.pm/config.json`, `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`, `LAST-SESSION.md`, `reports/`, `briefs/`.
- **Project-local reports vs a tool's global root.** A project's OWN report artifacts live under **`<root>/reports/`** (seeded by `/pm-init`). This is distinct from a tool's **global** `root` (`pm_tool_root <name>` — the shared, cross-project sink such as the log store). When this skill writes a report/output **for the active project** (e.g. a session summary artifact), target `<root>/reports/`; a tool's `root` / `pm_tool_root_or_notes <name>` is for that tool's cross-project archive.
- **Project-local briefs.** A project's `/orchestrate-brief` output lives under its **`briefs_dir`** (`.pm/config.json`, default **`<root>/briefs/`**, seeded by `/pm-init`), named `YYYY-MM-DD-<TICKET>-<slug>.md` — a per-project artifact dir like `<root>/reports/`. `/orchestrate-brief` produces `brief.md` at the orchestrate default `{artifact_root}/runs/<session_id>/`; resolve `briefs_dir` and relocate it there (`mkdir -p` + `mv`) — confirm the destination when interactive, move silently in automated runs — then pass the new path to `/orchestrate`. **Commit the relocated brief** — briefs live untracked in the project tree and a concurrent session can wipe an uncommitted one. Never modify orchestrate's global `artifact_root`.
- **Per-project tool override.** `.pm/config.json` MAY carry an optional `tools{}` block; after `pm_load_project <root>` the accessors resolve the **effective** tool = project override ?? global registry (per field), scoped to this project only — never mutating the global `~/.config/pm/config.json`. Precedence: project override > global > undefined (degrade).
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
TODO_SCOPE=$(jq -r '.tool_refs.todo // ""' "$ROOT/.pm/config.json")   # todo tag/list for this project
KEYWORDS=$(jq -r '.keywords | join(" ")' "$ROOT/.pm/config.json")
```

### Step 2 — GUARD (mandatory, always first action of substance)

**Same guard as `/pm-status`.** Both halves guarded independently:

1. **`tool:logs` sweep** — **if `pm_tool_defined logs` is false:** skip and print "tool:logs not defined — skipping hygiene sweep." **Else:** invoke the `logs` tool's configured provider in backfill mode (its sweep/backfill skill — see `pm_tool_skills logs`): scan the session for unlogged state-changes and auto-write the missing entries. _related: `pm_tool_skills logs`._
2. **`tool:todo` hygiene** — **if `pm_tool_defined todo` is false:** skip and print "tool:todo not defined — skipping task hygiene." **Else:** update the `todo` tool's configured provider — complete tasks finished this session, add new tasks surfaced, set due dates where known. Tag new tasks with `$TODO_SCOPE`.

### Step 3 — Summarize the session's log for this project — `tool:logs`

- **If `pm_tool_defined logs` is false:** summarize from your own memory of the session (what got done, decisions, anything left open) and note "tool:logs not defined — summary from session memory only". This summary feeds Steps 4 and 5.
- **Else:** read this session's entries from the `logs` tool's configured provider and filter to this project (`$TODO_SCOPE` / `$KEYWORDS`). Resolve the log store from the tool's `root` (falling back to `$PM_NOTES_ROOT`):

  ```bash
  LOG_ROOT="$(pm_tool_root_or_notes logs)"        # the logs tool's store (its root, else $PM_NOTES_ROOT)
  # Read today's entries under $LOG_ROOT in the provider's own layout/index
  # (e.g. a dated file or the provider's search skill — see pm_tool_skills logs).
  ```

  Produce a short summary from the log entries: what got done, decisions made, anything left open.

### Step 4 — Write a tagged journal entry — `tool:todo`

- **If `pm_tool_defined todo` is false:** skip with a note — there is no journal sink. (The `LAST-SESSION.md` block in Step 5 is the durable record.)
- **Else:** record a one-line journal note via the `todo` tool's configured provider, tagged with `$TODO_SCOPE`, e.g. a note reading:

  ```
  pm-end ${NAME}: <one-line summary of the session> #${TODO_SCOPE}
  ```

  Keep it one line. Add a second one-line note only for a distinct learning or follow-up. _related: `pm_tool_skills todo`._

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

If the project folder is inside a git repo, land the session's work on **this session's own branch** `chore/<day>-<slug>-pm-<shortsid>` — never push directly to `main`. This is a **frozen-HEAD commit** (`lib/commit-paths.sh`, sourced by `lib/session-commit.sh`): the shared repo's real HEAD, index, and working tree are never touched. There is no checkout of the session branch, no restore step afterward, and therefore no "which branch did the tree end up on" hazard — the commit is assembled entirely against a scratch git index, so two tabs committing at the same moment never interleave a checkout/add/commit sequence in the one shared tree. If the commit-message hook rejects the message elsewhere in this repo, that hook never runs here — this plumbing path lints the message itself (single line, ≤50 chars, conventional-commit shape) and aborts rather than writing a non-conforming commit; never bypass hooks (never `--no-verify`).

The helper stages the allowlist — everything dirty (modified + untracked) under the project folder — **minus the churn exclusion set** (`CALENDAR.*`, `meetings.jsonl`, `.pm/`, `LAST-SESSION.md`): those files are written continuously by every pane on the project and are committed once daily by the **EOD sweep** (`pa-eod-wrap`) across every registered project root, never by this per-session step. Committing them here would mean N session branches each carrying the same `CALENDAR.md`/`meetings.jsonl` change, colliding at EOD reconciliation. It skips the commit when the (non-churn) allowlist is empty (no empty commit). If the project is not in a git repo, it prints a notice and skips. `$SID` and `$NAME` were resolved in Step 1.

**This local commit runs in BOTH modes.** What happens *after* it depends on the per-project `auto_ship` flag in `.pm/config.json` (default `false`).

```bash
AUTO_SHIP=$(jq -r '.auto_ship // false' "$ROOT/.pm/config.json")
BRANCH=$("{{framework_root}}/lib/session-commit.sh" --root "$ROOT" --session "$SID" --name "$NAME")
```

Only paths under `$ROOT` (minus the churn exclusion set above) are ever staged; everything else — including unrelated dirty files outside the project folder — is left exactly as it was, since nothing here ever runs a checkout, reset, stash, or clean against the repo.

#### Mode A — `auto_ship=false` (default): stop after the local commit

The default. Leave the per-session branch local and **do not** push or open a PR from this step. Because each tab produces its own `chore/<day>-<slug>-pm-<shortsid>` branch, reconcile them at end of day using only ref-safe commands that never switch, reset, or otherwise touch the shared tree's checked-out branch:

```bash
DAY=$(date +%Y-%m-%d); SLUG=$(printf '%s' "$NAME" | tr '[:upper:] ' '[:lower:]-')
REPO=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)
# List today's per-session pm branches:
git -C "$REPO" branch --list "chore/$DAY-$SLUG-pm-*"
# Push each session branch and ship it through its own PR (one per branch, or open one
# day-bundle PR against a single collector branch — either way, only REFS move):
git -C "$REPO" push -u origin "chore/$DAY-$SLUG-pm-<shortsid>"
( cd "$REPO" && gh pr create --base main --head "chore/$DAY-$SLUG-pm-<shortsid>" \
    --title "docs(pm): $SLUG session $DAY" --body "Automated /pm-end session ship." )
( cd "$REPO" && gh pr merge "chore/$DAY-$SLUG-pm-<shortsid>" --merge --delete-branch )
# Update the origin/main REMOTE-TRACKING ref only — `git fetch origin main` never writes
# to a LOCAL branch, so it is safe even when `main` is the shared tree's checked-out
# branch (an explicit `origin main:main` refspec is NOT safe here — git refuses to write
# a local branch that is checked out in this or any linked worktree, which `main` usually
# is in the shared tree; that failure mode is exactly what this whole change eliminates
# elsewhere, so don't reintroduce it here):
git -C "$REPO" fetch origin main
# Verify by ancestry against the remote-tracking ref, never by PR state:
git -C "$REPO" merge-base --is-ancestor <session-commit-sha> origin/main && echo "landed"
# The shared tree's own LOCAL main still drifts behind origin/main until a separate,
# deliberate quiet-hours fast-forward (`git fetch && git merge --ff-only`, run only when
# the tree is clean and no pane is mid-session) — out of scope for this step by design.
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
- **Else:** record via the `logs` tool's configured provider an action entry like: `pm-end: wrapped '<name>' — journal logged, LAST-SESSION.md updated`.

### Step 7b — Mark this session closed (stop advertising it to sibling panes)

Other panes discover live work via `active-panes.sh`, which treats every marker with a live
transcript as an open pane. Wrapping up must therefore say so explicitly, or this pane keeps
appearing in every sibling's "other panes on this project now" until its transcript goes cold.

**The marker file itself is deliberately left in place** — deleting it would break a later
`/pm-status` in this same pane, and `/pm-end` is not always the last thing you do. Only the
sidecar changes how *others* see this session; `/pm-start` clears it if you reopen.

```bash
mkdir -p "{{framework_root}}/sessions/.closed"
date '+%Y-%m-%d %H:%M' > "{{framework_root}}/sessions/.closed/$SID"
```

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
- **Commit (when in a repo) is scoped to the project folder, minus the churn exclusion set** — stage only paths under `$ROOT` (excluding `CALENDAR.*`, `meetings.jsonl`, `.pm/`, `LAST-SESSION.md` — those are the EOD sweep's), on **this session's own branch** `chore/<day>-<slug>-pm-<shortsid>` (never the shared per-day branch). It is a **frozen-HEAD commit** (`lib/commit-paths.sh`): the shared repo's real HEAD, index, and working tree are never touched, so there is nothing to "restore" and no branch the tree is ever left on other than the one it was already on. Never push to `main`, never stage files outside the project folder. Reconcile the per-session branches at end of day (see Step 6).
- **`auto_ship` (per-project, `.pm/config.json`, default `false`)** — when `false`, the session branch stays local and you reconcile at EOD (Mode A). When `true`, `/pm-end` auto-ships the branch via the PR workflow (push branch → `gh pr create` → `gh pr merge --merge --delete-branch`), only when a commit was actually made and a remote exists — never a direct push to `main`, never `--no-verify` (Mode B).

## Signal Keywords
<!-- Comma-separated terms the skills collector uses to attribute learnings to this skill -->
pm-end, pm-framework, eod-wrap, session-capture, last-session, handoff, hygiene-guard, project-manager
