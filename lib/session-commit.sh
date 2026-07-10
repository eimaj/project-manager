#!/usr/bin/env bash
#
# session-commit.sh — commit the PM project's session changes on a PER-SESSION branch.
#
# Every /pm-end used to check out and commit to ONE shared per-day branch
# (chore/<day>-<slug>-pm) in the ONE shared working tree, so concurrent tabs raced on
# checkout / add / commit (interleaved index writes, "cannot lock ref", half-staged
# commits). This helper gives each session its OWN branch, keyed by a short, ref-safe
# form of the session id, so no two tabs touch the same ref or index-race.
#
# Usage:
#   session-commit.sh --root <root> --session <sid> [--name <project name>]
#   Echoes the branch name it committed on (empty output when not a git repo).
#
# Behavior (mirrors the old Step 6 invariants, minus the cross-tab race):
#   - Target branch: chore/<day>-<slug>-pm-<shortsid>  (per SESSION, not per day).
#   - Stage ONLY the project folder ($REL/) — never anything outside it.
#   - Skip the commit when there are no changes under the project folder (no empty commit).
#   - Never push, never target main, never bypass hooks.
#   - The working tree is SHARED across tabs, so capture the branch the user was on
#     before switching and restore it afterward — one tab's /pm-end must not leave a
#     concurrent tab checked out on this tab's pm branch. A detached HEAD restores to
#     its short SHA.
#
# Tool-agnostic: this helper only runs git in the project's repo. It names no meeting
# source, tracker, or logger — those live behind capability slots resolved elsewhere.
#
# Safe to source: it defines session_shortsid + session_commit and only auto-runs when
# EXECUTED directly (so tests can source and assert on the pure sanitizer).

# session_shortsid <sid> -> ref-safe short suffix: [a-z0-9-], collapsed, trimmed, <=12
# chars. Handles SIDs with '/', spaces, or the tty-.../shell-$PPID fallbacks. Falls back
# to a numeric checksum if a pathological all-symbol SID sanitizes to empty (keeps the
# suffix distinct and the branch name well-formed).
session_shortsid() {
  local short
  short=$(printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '-' \
    | sed -E 's/-+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-12)
  short="${short%-}"                      # cut may leave a trailing '-' at the 12-char edge
  if [[ -z "$short" ]]; then
    short=$(printf '%s' "$1" | cksum | cut -d' ' -f1 | cut -c1-8)
  fi
  printf '%s' "$short"
}

# session_commit <root> <sid> <name> — commit <root>/ on this session's own branch.
session_commit() {
  local ROOT="$1" SID="$2" NAME="$3"
  local REPO REL DAY SLUG SHORT BRANCH ORIG_BRANCH
  REPO=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null) || REPO=""
  if [[ -z "$REPO" ]]; then
    echo "session-commit.sh: not a git repo — skipping commit" >&2
    return 0
  fi
  REL="${ROOT#"$REPO"/}"
  DAY=$(date +%Y-%m-%d)
  SLUG=$(printf '%s' "$NAME" | tr '[:upper:] ' '[:lower:]-')
  SHORT=$(session_shortsid "$SID")
  BRANCH="chore/$DAY-$SLUG-pm-$SHORT"      # per-SESSION branch — no cross-tab ref race
  # Record the current branch so we can restore it (the working tree is shared!).
  ORIG_BRANCH=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null \
    || git -C "$REPO" rev-parse --short HEAD 2>/dev/null)
  if git -C "$REPO" rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
    git -C "$REPO" checkout "$BRANCH" >/dev/null 2>&1
  else
    git -C "$REPO" checkout -b "$BRANCH" >/dev/null 2>&1
  fi
  git -C "$REPO" add "$REL/"               # only the project folder — nothing outside $REL/
  if ! git -C "$REPO" diff --cached --quiet -- "$REL/"; then
    git -C "$REPO" commit -m "docs(pm): $SLUG session $DAY" >/dev/null   # <=50 chars
  fi
  # Restore the branch the user was on so the shared tree isn't left on the pm branch.
  [[ -n "$ORIG_BRANCH" ]] && git -C "$REPO" checkout "$ORIG_BRANCH" >/dev/null 2>&1 || true
  printf '%s\n' "$BRANCH"                   # emit the branch used (for callers / tests)
}

# Auto-run only when executed directly, not when sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  ROOT=""; SID=""; NAME=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root)    ROOT="$2"; shift 2 ;;
      --session) SID="$2"; shift 2 ;;
      --name)    NAME="$2"; shift 2 ;;
      -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) echo "session-commit.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
  done
  [[ -n "$ROOT" && -n "$SID" ]] || { echo "session-commit.sh: --root and --session are required" >&2; exit 2; }
  [[ -d "$ROOT" ]] || { echo "session-commit.sh: root does not exist: $ROOT" >&2; exit 2; }
  session_commit "$ROOT" "$SID" "$NAME"
fi
