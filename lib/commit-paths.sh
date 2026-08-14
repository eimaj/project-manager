#!/usr/bin/env bash
#
# commit-paths.sh — build a commit onto an explicit branch using a TEMP index, so the
# repo's real HEAD, index, and working tree are never disturbed. "Frozen-HEAD" commits.
#
# Why this exists: the shared `~/Code/logs` working tree is driven by several concurrent
# panes. Every recorded incident there reduces to one of two mechanisms — (M1) something
# moved HEAD of the shared checkout (a branch-switch race, or a restore that failed and
# stranded the tree on the wrong branch), or (M2) something copied stale directory
# content into a commit (a worktree `rsync -a` of a directory that had drifted behind
# origin). This helper makes both structurally impossible for the commits it builds:
#   - no branch-switch of any kind ever runs against the target repo — the commit is
#     assembled entirely against a scratch index, never the repo's real one;
#   - only an explicit, named file list is ever staged — never a directory copy.
#
# Usage:
#   commit-paths.sh --repo <path> --branch <name> --message <msg> \
#                    --paths <p1> [<p2> ...] [--append-only <prefix>] [--append-only <prefix> ...]
#   Prints the new commit sha on stdout on success. Prints nothing and exits 0 when the
#   resulting tree is identical to the branch tip (no-op skip — never an empty commit).
#
# --paths entries are files, repo-relative or absolute. A DIRECTORY entry is expanded at
# call time to the files `git status --porcelain` reports dirty under it (modified +
# untracked) — the expansion is always echoed to stderr, so a directory argument never
# sweeps content in silently.
#
# --append-only <prefix> (repeatable — pass it once per prefix) marks a path prefix as
# append-only: if the resulting diff shows NET deletions under that prefix (more lines
# removed than added), the whole call aborts loudly and NOTHING is written. This is the
# guard against exactly the M2 reversion incident: a stale copy of an append-only log
# would show as a net-negative diff against the branch tip.
#
# `git diff --numstat` reports "-" for add/del counts on a BINARY file — there is no line
# count to compare, so a binary file under an append-only prefix is UNVERIFIABLE, not
# safe-by-default: it also ABORTS (same exit code as the net-negative case), naming the
# file as binary. The guard exists for loss protection, so an unmeasurable diff is treated
# as a potential loss rather than silently waved through.
#
# Mechanism (every git call here is read-only with respect to the repo's OWN HEAD, index,
# and working tree — nothing here ever runs a working-tree checkout/switch, a stash, a
# reset of the index or tree, or a clean of untracked files):
#   0. --branch is asserted to NOT be the repo's currently checked-out branch, before any
#      other work. If it were, HEAD is a SYMBOLIC ref to refs/heads/$BRANCH, so the plain
#      `update-ref` this script ends with would move HEAD out from under the real index
#      and working tree directly — bypassing every safety check an ordinary checkout
#      performs (it would refuse a checkout that could clobber uncommitted state; a bare
#      ref update has no such check). The real index still reflects the OLD tip while
#      HEAD now points past it, so `git status` reports the same file as BOTH
#      staged-for-deletion (index lacks what the new HEAD has) and untracked (the
#      unchanged working-tree file no longer matches the index) — reproduced directly:
#      `--branch main` while `main` is checked out moves the repo's real HEAD sha and
#      corrupts `git status` immediately. This is exactly the M1 failure class the whole
#      file exists to make impossible, so it is asserted rather than merely documented.
#   1. PARENT = the tip of --branch if it already exists, else the repo's current HEAD
#      commit. This is the honest ancestry the new commit is built from.
#   2. A brand-new scratch index file (`mktemp`, removed by a trap on the subshell's
#      exit — success or failure) is pointed to via GIT_INDEX_FILE. `git read-tree
#      $PARENT` seeds it with PARENT's tree, then `git add -- <files>` stages ONLY the
#      resolved file list into that scratch index. The repo's real `.git/index` is never
#      opened.
#   3. The append-only guard (if any prefixes were given) inspects
#      `git diff --cached --numstat $PARENT` against the scratch index and aborts before
#      anything is written if a guarded file is net-negative.
#   4. The commit message is linted directly (single line, <=50 chars, conventional-commit
#      shape) BEFORE any of the above runs. This plumbing path never fires a commit-msg
#      hook, so linting here is what preserves the "no-bypass" rule the porcelain gets
#      from its hook — skipping this check would be a silent hook bypass.
#   5. `git write-tree` on the scratch index; if that tree equals PARENT's tree, exit 0
#      silently (no-op skip — nothing to commit, no empty commit created).
#   6. `git commit-tree $TREE -p $PARENT -m "$MESSAGE"` builds the commit object, then
#      `git update-ref refs/heads/$BRANCH $NEW <old-value>` lands it as an atomic
#      compare-and-swap: <old-value> is PARENT when the branch already existed, or the
#      empty string when it didn't (empty asserts non-existence — git update-ref refuses
#      the write if the ref was created out from under us in the meantime). On CAS
#      failure (another writer landed a commit on this branch first) the tip is
#      re-resolved and the whole build (steps 1-6, guard included) is retried exactly
#      once against the new tip; a second CAS failure fails loud with a distinct exit
#      code rather than retrying forever.
#
# Exit codes: 0 success (sha printed) or silent no-op; 2 usage/arg error; 3 --branch is
# the repo's checked-out branch (refused, see mechanism step 0); 10 message lint failure;
# 20 append-only guard triggered (net deletions, or a binary file under a guarded prefix);
# 21-24 an unexpected git-plumbing failure mid-build; 30 the one-shot CAS retry also failed.
#
# Safe to source: this file defines `commit_paths` (and private `_cp_*` helpers) and only
# auto-runs when EXECUTED directly — mirrors session-commit.sh so callers (session-commit.sh
# itself; any script needing a frozen-HEAD commit) can `source` it and call `commit_paths`
# with the same flags the CLI takes.

# _cp_lint_message <msg> — the same rule the repo's commit-msg hook enforces, run directly
# here because this plumbing path fires no hooks at all (see mechanism step 4 above).
_cp_lint_message() {
  local msg="$1"
  if [[ "$msg" == *$'\n'* ]]; then
    echo "commit-paths.sh: message must be a single line: $msg" >&2
    return 1
  fi
  if (( ${#msg} > 50 )); then
    echo "commit-paths.sh: message exceeds 50 chars (${#msg}): $msg" >&2
    return 1
  fi
  if ! [[ "$msg" =~ ^(feat|fix|docs|style|refactor|perf|test|chore|ci)\([a-z0-9][a-z0-9.-]*\):\ [^[:space:]] ]]; then
    echo "commit-paths.sh: message fails conventional-commit lint: $msg" >&2
    return 1
  fi
  return 0
}

# _cp_expand_paths <repo> <path...> — echo one resolved file per line on stdout; a
# directory arg becomes the files `git status --porcelain` reports dirty under it
# (modified + untracked). Always echoes what a directory expanded to, to stderr, so
# nothing is swept in silently.
#
# Renames (status R) contribute BOTH paths, not just the new one: `git status -z` pairs
# a rename as "new-path\0orig-path\0", and the scratch index is seeded via `read-tree
# $PARENT`, which still has the ORIG path tracked. `git add -- <newpath>` alone never
# removes it — the resulting tree would carry both the old and new path (reviewer-
# reproduced: `git mv a b` then committing left both `a` and `b` in the tree). Passing
# the orig path to `git add --` EXPLICITLY (not via a directory/wildcard pathspec) does
# correctly stage its removal when it's gone from the working tree — this is documented,
# ordinary `git add` behavior, not a special case this script has to implement — so
# including it in the file list is sufficient; no `git rm --cached` needed.
# Copies (status C) contribute both paths too: the orig path is unaffected by a copy (it
# still exists on disk), so re-adding it is a harmless no-op against the unchanged
# scratch-index entry inherited from PARENT — never a spurious removal.
_cp_expand_paths() {
  local repo="$1"; shift
  local p abs
  for p in "$@"; do
    if [[ "$p" = /* ]]; then abs="$p"; else abs="$repo/$p"; fi
    if [[ -d "$abs" ]]; then
      local -a raw=() expanded=()
      # --untracked-files=all: without it, a wholly-untracked directory collapses to a
      # single "?? dir/" entry instead of one entry per file inside it.
      while IFS= read -r -d '' entry; do raw+=("$entry"); done \
        < <(git -C "$repo" status --porcelain=v1 -z --untracked-files=all -- "$p")
      local i=0 st fpath
      while (( i < ${#raw[@]} )); do
        st="${raw[i]:0:2}"; fpath="${raw[i]:3}"
        expanded+=("$fpath")
        if [[ "$st" == R* || "$st" == C* ]]; then
          (( i++ ))
          expanded+=("${raw[i]}")   # the paired orig path — see the rename/copy note above
        fi
        (( i++ ))
      done
      echo "commit-paths.sh: expanded dir '$p' -> ${expanded[*]:-<nothing dirty>}" >&2
      # bash 3.2 (macOS system bash) treats a zero-length array as unset under `set -u`,
      # so a bare "${expanded[@]}" would abort here when the dir had nothing dirty. The
      # ${arr[@]+"${arr[@]}"} idiom expands to nothing in that case instead of erroring.
      local f
      for f in "${expanded[@]+"${expanded[@]}"}"; do printf '%s\n' "$f"; done
    else
      printf '%s\n' "$p"
    fi
  done
}

# commit_paths --repo <path> --branch <name> --message <msg> --paths <p...> \
#              [--append-only <prefix>]...
commit_paths() {
  local REPO_ARG="" BRANCH="" MESSAGE=""
  local -a PATH_ARGS=() APPEND_ONLY=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)    REPO_ARG="$2"; shift 2 ;;
      --branch)  BRANCH="$2"; shift 2 ;;
      --message) MESSAGE="$2"; shift 2 ;;
      --paths)
        shift
        while [[ $# -gt 0 && "$1" != --* ]]; do PATH_ARGS+=("$1"); shift; done
        ;;
      --append-only) APPEND_ONLY+=("$2"); shift 2 ;;
      -h|--help) grep '^#' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; return 0 ;;
      *) echo "commit-paths.sh: unknown arg: $1" >&2; return 2 ;;
    esac
  done

  [[ -n "$REPO_ARG" && -n "$BRANCH" && -n "$MESSAGE" ]] \
    || { echo "commit-paths.sh: --repo, --branch, and --message are required" >&2; return 2; }
  [[ ${#PATH_ARGS[@]} -gt 0 ]] \
    || { echo "commit-paths.sh: --paths requires at least one entry" >&2; return 2; }

  local REPO
  REPO="$(git -C "$REPO_ARG" rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "commit-paths.sh: not a git repo: $REPO_ARG" >&2; return 2; }

  # --branch must NEVER be the repo's currently checked-out branch (see mechanism note
  # below and the header). Checked before any other work.
  local checked_out
  checked_out="$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null)"
  if [[ -n "$checked_out" && "$checked_out" == "$BRANCH" ]]; then
    echo "commit-paths.sh: --branch '$BRANCH' is the repo's checked-out branch — refusing." >&2
    echo "commit-paths.sh: HEAD symbolically points at refs/heads/$BRANCH, so update-ref would" >&2
    echo "commit-paths.sh: move HEAD out from under the real index/working tree without going" >&2
    echo "commit-paths.sh: through a checkout's safety checks — the real index would still" >&2
    echo "commit-paths.sh: reflect the OLD tip while HEAD now points past it, corrupting" >&2
    echo "commit-paths.sh: 'git status' (files show as both staged-deleted and untracked)." >&2
    return 3
  fi

  _cp_lint_message "$MESSAGE" || return 10

  local -a FILES=()
  while IFS= read -r line; do [[ -n "$line" ]] && FILES+=("$line"); done \
    < <(_cp_expand_paths "$REPO" "${PATH_ARGS[@]}")
  if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "commit-paths.sh: no files resolved from --paths — nothing to commit" >&2
    return 0
  fi

  # PARENT: the branch's own tip if it exists, else the repo's current HEAD (honest
  # ancestry — see mechanism step 1 in the header).
  local PARENT BRANCH_EXISTED=0
  if PARENT="$(git -C "$REPO" rev-parse -q --verify "refs/heads/$BRANCH" 2>/dev/null)"; then
    BRANCH_EXISTED=1
  else
    PARENT="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)" \
      || { echo "commit-paths.sh: cannot resolve HEAD in $REPO" >&2; return 2; }
  fi

  local OUT RC
  # Deliberately UNQUOTED command substitution on this assignment: `VAR=$(...)` never
  # word-splits its RHS (that only happens in a bare/expansion context, not an
  # assignment), and quoting it as `VAR="$(...)"` triggers a bash parser quirk where an
  # apostrophe inside a `#` comment nested in here breaks the outer quote-matching.
  OUT=$(
    TMPIDX="$(mktemp)" || exit 2
    trap 'rm -f "$TMPIDX"' EXIT
    export GIT_INDEX_FILE="$TMPIDX"

    # _cp_attempt <parent> — read-tree parent onto the scratch index, stage FILES, run
    # the append-only guard, write-tree, and (unless it's a no-op) commit-tree. Prints
    # the new commit sha, or the literal "NOOP", on stdout; returns non-zero (a distinct
    # code per failure point) without printing anything on any failure.
    _cp_attempt() {
      local parent="$1"
      git -C "$REPO" read-tree "$parent" || return 21
      git -C "$REPO" add -- "${FILES[@]}" || return 22

      if [[ ${#APPEND_ONLY[@]} -gt 0 ]]; then
        local add del fpath prefix
        while IFS=$'\t' read -r add del fpath; do
          [[ -z "$fpath" ]] && continue
          for prefix in "${APPEND_ONLY[@]}"; do
            [[ "$fpath" == "$prefix"* ]] || continue
            # Binary: numstat reports "-"/"-" — no line count to compare, so the diff is
            # UNVERIFIABLE, not safe-by-default. Abort the same as a net-negative diff
            # (see the --append-only doc note in the header): the guard exists for loss
            # protection, and an unmeasurable file under a guarded prefix is a potential
            # loss, not a pass.
            if [[ "$add" == "-" || "$del" == "-" ]]; then
              echo "commit-paths.sh: append-only guard: '$fpath' is binary (no line-count signal) under '$prefix' — aborting, nothing written" >&2
              return 20
            fi
            if (( del > add )); then
              echo "commit-paths.sh: append-only guard: '$fpath' net deletions ($del > $add) under '$prefix' — aborting, nothing written" >&2
              return 20
            fi
          done
        done < <(git -C "$REPO" diff --cached --numstat "$parent")
      fi

      local tree parent_tree
      tree="$(git -C "$REPO" write-tree)" || return 23
      parent_tree="$(git -C "$REPO" rev-parse "${parent}^{tree}" 2>/dev/null)" || return 23
      if [[ "$tree" == "$parent_tree" ]]; then
        echo "NOOP"
        return 0
      fi
      local new
      new="$(git -C "$REPO" commit-tree "$tree" -p "$parent" -m "$MESSAGE")" || return 24
      echo "$new"
    }

    result="$(_cp_attempt "$PARENT")"; rc=$?
    (( rc != 0 )) && exit "$rc"
    [[ "$result" == "NOOP" ]] && exit 0

    old_value=""
    [[ "$BRANCH_EXISTED" == 1 ]] && old_value="$PARENT"
    if git -C "$REPO" update-ref "refs/heads/$BRANCH" "$result" "$old_value" 2>/dev/null; then
      echo "$result"
      exit 0
    fi

    # CAS lost the race to a concurrent writer on this same branch. Re-resolve the tip
    # and rebuild exactly once against it; a second CAS loss fails loud rather than
    # retrying forever.
    echo "commit-paths.sh: CAS on refs/heads/$BRANCH lost the race — retrying once" >&2
    newparent="$(git -C "$REPO" rev-parse -q --verify "refs/heads/$BRANCH" 2>/dev/null)" \
      || newparent="$(git -C "$REPO" rev-parse HEAD)"
    result="$(_cp_attempt "$newparent")"; rc=$?
    (( rc != 0 )) && exit "$rc"
    [[ "$result" == "NOOP" ]] && exit 0

    retry_old=""
    git -C "$REPO" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null 2>&1 && retry_old="$newparent"
    if git -C "$REPO" update-ref "refs/heads/$BRANCH" "$result" "$retry_old"; then
      echo "$result"
      exit 0
    fi
    echo "commit-paths.sh: CAS retry on refs/heads/$BRANCH also failed — aborting, nothing written" >&2
    exit 30
  )
  RC=$?
  [[ -n "$OUT" ]] && printf '%s\n' "$OUT"
  return "$RC"
}

# Auto-run only when executed directly, not when sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  commit_paths "$@"
  exit $?
fi
