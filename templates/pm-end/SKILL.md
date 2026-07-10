---
name: pm-end
description: End-of-session capture for the active PM project — runs the logger hygiene guard first (when a logger is configured), summarizes the session, writes a tagged note, and updates this session's block in LAST-SESSION.md (current state / open threads / next-up / blockers) without clobbering other sessions' blocks. Use when wrapping up work on a project, "/pm-end", or "I'm done for now".
---

# pm-end — Capture & Hand Off (EOD)

> Rendered by `/pm-generate` from a tool-agnostic template. Slot names below were filled
> from your mapping; logic talks to slots only and degrades when a slot is `none`.

## Trigger

**Use when:** wrapping up a work session on the active project — "I'm done", "wrap up", "/pm-end". Captures state so the next `/pm-start` can lead with it.
**Do NOT use when:** opening the session → `/pm-start`. A quick mid-session recap → `/pm-status`.
**Inputs expected:** none — resolves the project from the per-session marker.
**Outputs produced:** backfilled logger entries (the guard, if a logger is configured); a tagged note (if logger/notes support it); an updated `<root>/LAST-SESSION.md` block for this session.

## Related Skills

- [`pm-start`](../pm-start/SKILL.md) — opens the next session, reads the `LAST-SESSION.md` this skill writes
- [`pm-status`](../pm-status/SKILL.md) — cache-only mid-session briefing

---

## Framework facts (shared across all four pm-* skills)

- **Per-session marker:** `{{framework_root}}/sessions/<session-id>` holds the active project root (`<session-id>` via `{{framework_root}}/lib/session.sh`). **This skill reads it** (does not write it).
- **Capability slots (your mapping):** meeting source = **{{meeting_source}}**, tracker = **{{tracker}}**, logger = **{{logger}}**, email = **{{email}}**, notes store root = **{{notes_root}}**.
- **Per-project files** (in `<root>`): `.pm/config.json`, `CONTEXT.md`, `CALENDAR.md`, `meetings.jsonl`, `LAST-SESSION.md`.
- **History lives in the logger; the handoff lives in `LAST-SESSION.md`.** There is **no JOURNAL.md** — `LAST-SESSION.md` carries one block per session (it is a forward handoff, not a log).

## Steps

### Step 1 — Resolve the project from the marker

```bash
SID=$("{{framework_root}}/lib/session.sh")        # same resolver pm-start used to write the marker
ROOT="$(cat "{{framework_root}}/sessions/$SID" 2>/dev/null)"
test -f "$ROOT/.pm/config.json" || { echo "No active PM project this session — run /pm-start @<path> first."; exit 1; }
NAME=$(jq -r '.name' "$ROOT/.pm/config.json")
NOTES_REF=$(jq -r '.notes_ref // ""' "$ROOT/.pm/config.json")
KEYWORDS=$(jq -r '.keywords | join(" ")' "$ROOT/.pm/config.json")
```

### Step 2 — GUARD (hygiene; logger slot)

**Same guard as `/pm-status`.**

- **If the `logger` slot is `none`:** **skip the logger sweep** and print "logger slot is none — skipping hygiene sweep."
- **Else:** invoke the **{{logger}}** sweep/backfill flow — scan the session for unlogged state-changes and auto-write the missing entries. If your logger has no sweep concept, record one summary entry.

### Step 3 — Summarize the session — logger slot

- **If the `logger` slot is `none`:** summarize from your own memory of the session (what got done, decisions, anything left open). This summary feeds Steps 4 and 5.
- **Else:** read recent **{{logger}}** entries for this project (`NOTES_REF` / `KEYWORDS`) and produce a short summary: what got done, decisions made, anything left open.

### Step 4 — Write a tagged note (optional; logger/notes slot)

- **If the `logger` slot is `none`:** skip — there is no note sink. (The `LAST-SESSION.md` block in Step 5 is the durable record.)
- **Else:** record a one-line note via **{{logger}}**, tagged with `NOTES_REF`, e.g. `pm-end <name>: <one-line summary of the session>`. Add a second one-line note only for a distinct learning or follow-up.

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

If the project folder is inside a git repo, land the session's work via a single **per-day branch + PR** — never push directly to `main`. **Stage ONLY the project folder (`$REL/`) — nothing outside it.** If there are no changes under the project folder, skip the commit (no empty commit). If the project is not in a git repo, skip this step.

```bash
REPO=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo — skipping commit"; REPO=""; }
if [[ -n "$REPO" ]]; then
  REL="${ROOT#"$REPO"/}"
  DAY=$(date +%Y-%m-%d)
  SLUG=$(printf '%s' "$NAME" | tr '[:upper:] ' '[:lower:]-')
  BRANCH="chore/$DAY-$SLUG-pm"
  if git -C "$REPO" rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
    git -C "$REPO" checkout "$BRANCH"
  else
    git -C "$REPO" checkout -b "$BRANCH"
  fi
  git -C "$REPO" add "$REL/"                       # only the project folder — nothing outside $REL/
  if ! git -C "$REPO" diff --cached --quiet -- "$REL/"; then
    git -C "$REPO" commit -m "docs(pm): $SLUG session $DAY"   # type(scope): subject, <=50 chars
  fi
fi
```

If the commit-message hook rejects the message, fix the message — never bypass hooks.

### Step 7 — Log it — logger slot

- **If the `logger` slot is `none`:** skip.
- **Else:** record via **{{logger}}**: `pm-end: wrapped '<name>' — note logged, LAST-SESSION.md updated`.

### Step 8 — Release the session color (optional)

If `/pm-start` set a session color, print a paste-ready line to reset the prompt bar. The conversation name stays (set via `/rename`); only the color is cleared:

```
/color default
```

Print this only when the project has a `session_color` configured; skip it otherwise.

## Rules

- **The guard runs first when a logger exists** — identical to `/pm-status`. When the `logger` slot is `none`, skip it and say so.
- **LAST-SESSION.md is per-session blocks** — write only *your* session's block via `handoff-write.sh` (it replaces your block, preserves others). Never overwrite the whole file: a concurrent session on the same project may own another block.
- **No JOURNAL.md** — do not create one.
- **Every slot has an explicit `none` branch** — never fabricate logger/tracker activity for a disabled slot.
- **Commit (when in a repo) is scoped to the project folder** — stage only paths under `$ROOT`, on a per-day branch; never push to `main`, never stage files outside the project folder.

## Signal Keywords
<!-- Comma-separated terms the skills collector uses to attribute learnings to this skill -->
pm-end, pm-framework, eod-wrap, session-capture, last-session, handoff, hygiene-guard, project-manager
