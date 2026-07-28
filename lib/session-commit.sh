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
# Concurrency: per-session BRANCHES removed the cross-tab *ref* race, but not the
# cross-tab *working-tree* race. checkout -> add -> commit -> restore mutates HEAD and
# the index, both shared by every pane in the tree. Two concurrent /pm-end runs interleave
# like this:
#
#   A: ORIG=main;        checkout BRANCH_A
#   B: ORIG=BRANCH_A  <- B captures A's branch as its "original"
#   B: checkout BRANCH_B
#   A: add + commit   <- lands on BRANCH_B, not BRANCH_A
#   A: checkout main
#   B: add + commit   <- lands on main
#
# So the tree-mutating half runs under a REPO-scoped lock (_sc_tree_critical). The lock is
# per-repo, NOT per-project: two panes on DIFFERENT projects in the same repo still share
# one tree and one HEAD. It is keyed on the git dir, so a linked worktree — which has its
# own tree and HEAD — locks independently and does not serialize against the main tree.
#
# Tool-agnostic: this helper only runs git in the project's repo. It names no meeting
# source, tracker, or logger — those live behind capability slots resolved elsewhere.
#
# Safe to source: it defines session_shortsid + session_commit and only auto-runs when
# EXECUTED directly (so tests can source and assert on the pure sanitizer).

# The tree lock must outlive a commit whose hooks run long (commit-msg linters, formatters).
# with-lock.sh's 30s default would let a second pane break a LIVE lock mid-commit — exactly
# the failure the lock exists to prevent — so raise the stale threshold before sourcing it.
# A caller-supplied PM_LOCK_STALE_AFTER still wins.
: "${PM_LOCK_STALE_AFTER:=300}"
# shellcheck source=with-lock.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/with-lock.sh"

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

# _sc_tree_critical — the tree-mutating half of session_commit, run UNDER the repo tree
# lock. Reads REPO / REL / BRANCH / ORIG_BRANCH from session_commit's frame via bash
# dynamic scoping (the same pattern handoff-write.sh's write_handoff_block uses).
#
# Every git call that moves HEAD or writes the index is checked: on failure we abort and
# leave the tree alone rather than staging the project folder onto whatever branch happens
# to be checked out. Silently continuing past a lost checkout is what turns a race into a
# wrong-branch commit.
_sc_tree_critical() {
  # Record the current branch so we can restore it (the working tree is shared!).
  ORIG_BRANCH=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null \
    || git -C "$REPO" rev-parse --short HEAD 2>/dev/null)
  # Capture the project files the CURRENT (base) branch does NOT track. If we commit them
  # onto the session branch and then restore base, base's checkout would DELETE them from
  # the SHARED working tree (they become "tracked in old HEAD, absent in new HEAD"). We
  # re-materialize exactly these after the restore so a snapshot commit never removes the
  # active project from the tree. (.gitignore'd files are excluded — never added, never
  # committed, never at risk; and files already tracked on base restore normally.)
  local -a UNTRACKED=()
  while IFS= read -r -d '' f; do UNTRACKED+=("$f"); done \
    < <(git -C "$REPO" ls-files --others --exclude-standard -z -- "$REL/" 2>/dev/null)

  local co_rc=0
  if git -C "$REPO" rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
    git -C "$REPO" checkout "$BRANCH" >/dev/null 2>&1 || co_rc=$?
  else
    git -C "$REPO" checkout -b "$BRANCH" >/dev/null 2>&1 || co_rc=$?
  fi
  if (( co_rc != 0 )); then
    echo "session-commit.sh: could not switch to $BRANCH (rc=$co_rc) — aborting, nothing committed." >&2
    return 1
  fi

  if ! git -C "$REPO" add "$REL/"; then     # only the project folder — nothing outside $REL/
    echo "session-commit.sh: 'git add $REL/' failed — restoring $ORIG_BRANCH, nothing committed." >&2
    [[ -n "$ORIG_BRANCH" ]] && git -C "$REPO" checkout "$ORIG_BRANCH" >/dev/null 2>&1
    return 1
  fi
  local committed=0
  if ! git -C "$REPO" diff --cached --quiet -- "$REL/"; then
    git -C "$REPO" commit -m "docs(pm): $SLUG session $DAY" >/dev/null   # <=50 chars
    committed=1
  fi
  # Restore the branch the user was on so the shared tree isn't left on the pm branch.
  if [[ -n "$ORIG_BRANCH" ]] && ! git -C "$REPO" checkout "$ORIG_BRANCH" >/dev/null 2>&1; then
    echo "session-commit.sh: WARNING — could not restore '$ORIG_BRANCH'; tree left on $BRANCH." >&2
  fi
  # Re-materialize the files base does not track (the restore above deleted them), keeping
  # them UNTRACKED in the working tree: the snapshot lives on $BRANCH, the tree is unchanged.
  # Non-fatal (the snapshot is safely committed either way) but never silent: a failure here
  # means the project folder is missing from the tree and the user must know.
  if [[ "$committed" == 1 && ${#UNTRACKED[@]} -gt 0 ]]; then
    if ! git -C "$REPO" checkout "$BRANCH" -- "${UNTRACKED[@]}" >/dev/null 2>&1; then
      echo "session-commit.sh: WARNING — could not restore ${#UNTRACKED[@]} untracked file(s) under $REL/; recover them from $BRANCH." >&2
    fi
    git -C "$REPO" reset -q -- "$REL/" >/dev/null 2>&1 || true
  fi
  return 0
}

# session_commit <root> <sid> <name> — commit <root>/ on this session's own branch.
session_commit() {
  local ROOT="$1" SID="$2" NAME="$3"
  local REPO REL DAY SLUG SHORT BRANCH ORIG_BRANCH GITDIR
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
  # Serialize the tree-mutating half (see the concurrency note in the header). Key the lock
  # on the git dir so a linked worktree locks independently — .git is a FILE in a worktree,
  # so $REPO/.git is not a mkdir-able lock parent there.
  GITDIR=$(git -C "$REPO" rev-parse --absolute-git-dir 2>/dev/null) || GITDIR="$REPO/.git"
  with_lock "$GITDIR/.pm-tree.lock" _sc_tree_critical || return 1
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
