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
# Behavior:
#   - Target branch: chore/<day>-<slug>-pm-<shortsid>  (per SESSION, not per day).
#   - The allowlist is everything dirty (modified + untracked) under the project folder
#     ($REL/), MINUS the churn exclusion set (CALENDAR.*, meetings.jsonl, .pm/,
#     LAST-SESSION.md — those are owned by the EOD sweep, never by pm-end; see
#     lib/commit-paths.sh's header and templates/pm-end/SKILL.md Step 6).
#   - Skip the commit when the allowlist is empty (no empty commit) — the branch name is
#     still echoed either way, matching the pre-existing contract callers rely on.
#   - Never push, never target main, never bypass hooks.
#
# History — frozen-HEAD rewrite (2026-08-13): this used to switch the shared working
# tree onto the session branch, stage $REL/, commit, then switch back to whatever branch
# the tab was on before — restoring the ORIGINAL branch in a tree every other pane's
# session was ALSO reading and writing. A failed restore stranded the shared tree on the
# wrong branch for every pane (incident 4); a snapshot commit of an untracked project
# folder then deleted it from the working tree on restore, patched 2026-07-16 by
# re-materializing the snapshot afterward (incident 1) — a patch this rewrite removes,
# because there is no longer a restore step to patch around. The whole class (M1: something
# moves HEAD of the shared checkout) is now structurally impossible: this file never
# switches a branch, resets, stashes, or cleans the target repo — see the grep-assertable
# invariant in its test coverage. The commit is instead assembled by lib/commit-paths.sh
# entirely against a scratch git index — see its header for the mechanism. Because nothing
# here ever touches the repo's real HEAD or index, the per-repo tree lock this file used
# to take is no longer needed for this path (with-lock.sh stays in place, still used by
# handoff-write.sh / scaffold.sh, until every branch-switching caller is gone).
#
# Tool-agnostic: this helper only runs git in the project's repo. It names no meeting
# source, tracker, or logger — those live behind capability slots resolved elsewhere.
#
# Safe to source: it defines session_shortsid + session_commit and only auto-runs when
# EXECUTED directly (so tests can source and assert on the pure sanitizer).

# shellcheck source=commit-paths.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/commit-paths.sh"

# _sc_is_churn <repo-relative-path> <repo-relative-project-dir> — true if <path> falls
# under the churn exclusion set (owned by the EOD sweep: pa-eod-wrap / pa-eow-summary),
# false otherwise. Matched against the path with the project-dir prefix stripped, so the
# rule is the same regardless of where in the repo the project lives.
_sc_is_churn() {
  local fpath="$1" rel="$2" base
  base="${fpath#"$rel"/}"
  case "$base" in
    CALENDAR.*|meetings.jsonl|LAST-SESSION.md|.pm/*) return 0 ;;
    *) return 1 ;;
  esac
}

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

# session_commit <root> <sid> <name> — commit <root>/ on this session's own branch, via
# lib/commit-paths.sh (a frozen-HEAD commit: the shared repo's real HEAD, index, and
# working tree are never touched — see that file's header for the mechanism).
session_commit() {
  local ROOT="$1" SID="$2" NAME="$3"
  local REPO REL DAY SLUG SHORT BRANCH
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

  # Allowlist: everything dirty (modified + untracked) under the project folder, MINUS
  # the churn exclusion set (that belongs to the EOD sweep — see _sc_is_churn above).
  # --untracked-files=all: without it, a wholly-untracked subdirectory (e.g. a brand-new
  # reports/ folder) collapses to a single "?? dir/" entry instead of one per file, and
  # the churn check below needs real file paths to match against.
  #
  # Renames (status R) carry BOTH paths (git status -z pairs them as new\0orig\0). The
  # orig path must be passed to commit_paths too, not dropped — commit-paths.sh's own
  # scratch index is seeded from the branch tip, which still tracks the orig path; only
  # explicitly naming it lets `git add` stage its removal (see commit-paths.sh's header).
  # Copies (status C) pair the same way; the orig path is unaffected by a copy, so
  # re-adding it is a harmless no-op.
  local -a raw=() FILES=()
  while IFS= read -r -d '' entry; do raw+=("$entry"); done \
    < <(git -C "$REPO" status --porcelain=v1 -z --untracked-files=all -- "$REL/" 2>/dev/null)
  local i=0 st fpath
  while (( i < ${#raw[@]} )); do
    st="${raw[i]:0:2}"; fpath="${raw[i]:3}"
    _sc_is_churn "$fpath" "$REL" || FILES+=("$fpath")
    if [[ "$st" == R* || "$st" == C* ]]; then
      (( i++ ))
      _sc_is_churn "${raw[i]}" "$REL" || FILES+=("${raw[i]}")   # the paired orig path
    fi
    (( i++ ))
  done

  if [[ ${#FILES[@]} -eq 0 ]]; then
    printf '%s\n' "$BRANCH"    # nothing (non-churn) to commit; still emit the branch name
    return 0
  fi

  commit_paths --repo "$REPO" --branch "$BRANCH" \
    --message "docs(pm): $SLUG session $DAY" --paths "${FILES[@]}" >/dev/null || return 1
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
