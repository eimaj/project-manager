#!/usr/bin/env bash
#
# churn-sweep.sh — commit the PM churn files across every registered project.
#
# Why this exists: pm-end deliberately EXCLUDES the churn set (CALENDAR.*,
# meetings.jsonl, .pm/, LAST-SESSION.md) from its per-session commit — every pane on a
# project rewrites those, so N session branches would each carry the same diff and
# collide at reconciliation (see lib/session-commit.sh `_sc_is_churn`). The exclusion
# assumes a DAILY sweep owns them instead. Where that sweep is a work-specific skill
# that is disabled (or simply not installed), nothing owns them and a project's own
# `.pm/config.json` stays untracked indefinitely — in `~/Code/logs`'s case, untracked in
# a shared, concurrently-written repo where another session can wipe it.
#
# This script is that sweep, with no dependency on any tracker, MCP or work tooling: it
# reads the registry, groups the dirty churn files by containing repo, and lands ONE
# commit per repo on a dated branch.
#
# Usage:
#   churn-sweep.sh [--dry-run] [--ship] [--root <path>]... [--registry <file>]
#
#   --dry-run      list what would be committed, write nothing (default is to commit)
#   --ship         after committing, push the branch and open+merge a PR via `gh`
#                  (never pushes a base branch directly; skipped if `gh` is absent)
#   --root <path>  sweep only this project root (repeatable); default = every registry entry
#   --registry     override the registry path (default $PM_FRAMEWORK_ROOT/registry.jsonl)
#
# Safety properties, all inherited deliberately:
#   - Commits are built with lib/commit-paths.sh (frozen-HEAD): the repo's real HEAD,
#     index and working tree are never touched, so it is safe to run while other panes
#     are mid-session in the same worktree. No checkout, reset, stash or clean, ever.
#   - `--base origin/<default>` so a fresh daily branch is parented at a CURRENT ref
#     rather than a shared tree's deliberately-stale local main.
#   - meetings.jsonl and LAST-SESSION.md are passed as --append-only prefixes: if a
#     stale copy would show net line deletions, commit-paths.sh aborts and writes nothing.
#   - Only churn paths under a registered root are ever staged. Anything else dirty in
#     the repo — including another session's in-flight work — is left untouched.
#
# Exit codes: 0 success (including "nothing to do"); 2 usage error; 1 one or more repos
# failed (each failure is reported; the sweep continues to the next repo).

set -uo pipefail

FRAMEWORK_ROOT="${PM_FRAMEWORK_ROOT:-$HOME/.claude/pm}"
REGISTRY="$FRAMEWORK_ROOT/registry.jsonl"
COMMIT_PATHS="$FRAMEWORK_ROOT/lib/commit-paths.sh"
DRY_RUN=0
SHIP=0
declare -a ONLY_ROOTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; shift ;;
    --ship)     SHIP=1; shift ;;
    --root)     ONLY_ROOTS+=("${2:?--root needs a path}"); shift 2 ;;
    --registry) REGISTRY="${2:?--registry needs a path}"; shift 2 ;;
    -h|--help)  sed -n '2,42p' "$0"; exit 0 ;;
    *)          echo "churn-sweep: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "churn-sweep: jq is required." >&2; exit 2; }
[[ -r "$REGISTRY" ]] || { echo "churn-sweep: no registry at $REGISTRY" >&2; exit 2; }
[[ -x "$COMMIT_PATHS" ]] || { echo "churn-sweep: missing $COMMIT_PATHS" >&2; exit 2; }

# _is_churn <basename-or-relpath-under-root> — mirrors session-commit.sh `_sc_is_churn`.
# Keep these two in lockstep: this script's whole purpose is to own exactly what that
# function excludes, so a divergence would silently orphan a file class again.
_is_churn() {
  case "$1" in
    CALENDAR.*|meetings.jsonl|LAST-SESSION.md) return 0 ;;
    .pm/*)                                     return 0 ;;
  esac
  return 1
}

# Collect the roots to sweep.
declare -a ROOTS=()
if [[ ${#ONLY_ROOTS[@]} -gt 0 ]]; then
  ROOTS=("${ONLY_ROOTS[@]}")
else
  while IFS= read -r r; do [[ -n "$r" ]] && ROOTS+=("$r"); done \
    < <(jq -r '.root // empty' "$REGISTRY" | awk '!seen[$0]++')
fi
[[ ${#ROOTS[@]} -gt 0 ]] || { echo "churn-sweep: no project roots to sweep."; exit 0; }

# Group dirty churn paths by containing repo. macOS ships bash 3.2 (no associative arrays,
# no mapfile) and every other lib here targets it, so grouping goes through a temp file of
# "<repo>\t<repo-relative path>" lines rather than a hash.
PAIRS="$(mktemp)"
trap 'rm -f "$PAIRS"' EXIT

for ROOT in "${ROOTS[@]}"; do
  [[ -d "$ROOT" ]] || { echo "churn-sweep: skip (missing dir): $ROOT" >&2; continue; }
  # Resolve ROOT physically BEFORE deriving the repo-relative prefix. `--show-toplevel`
  # always returns a symlink-resolved path, so a registry root reached through a symlink
  # (a $TMPDIR path on macOS, or a `~/Code/pm`-style convenience link) is textually
  # different from it, the prefix strip below silently fails, and the pathspec becomes an
  # absolute path git matches nothing against — the sweep then reports "nothing dirty"
  # while quietly skipping a real project. Caught by the scratch-repo test.
  ROOT="$(cd -P "$ROOT" 2>/dev/null && pwd)" || {
    echo "churn-sweep: skip (unresolvable): $ROOT" >&2; continue; }
  REPO="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "churn-sweep: skip (not a git repo): $ROOT"; continue; }
  REL="${ROOT#"$REPO"/}"
  [[ "$REL" == "$ROOT" ]] && REL=""    # project root IS the repo root

  # Dirty (modified + untracked) files under the project dir, NUL-safe, expanded from
  # porcelain so an untracked directory (e.g. a brand-new .pm/) is walked into.
  while IFS= read -r -d '' f; do
    sub="${f#"$REL"/}"
    _is_churn "$sub" || continue
    printf '%s\t%s\n' "$REPO" "$f" >> "$PAIRS"
  done < <(git -C "$REPO" status --porcelain -z --untracked-files=all -- "${REL:-.}" \
           | while IFS= read -r -d '' entry; do
               # porcelain -z: "XY <path>"; rename entries emit the orig path as a
               # separate NUL record, which we simply treat as another candidate.
               printf '%s\0' "${entry:3}"
             done)
done

[[ -s "$PAIRS" ]] || { echo "churn-sweep: nothing dirty in the churn set — nothing to do."; exit 0; }

DAY="$(date +%F)"
RC=0

while IFS= read -r REPO; do
  [[ -n "$REPO" ]] || continue
  FILES=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && FILES+=("$f")
  done < <(awk -F'\t' -v r="$REPO" '$1==r{print $2}' "$PAIRS" | sort -u)
  [[ ${#FILES[@]} -gt 0 ]] || continue

  echo "repo: $REPO"
  printf '  %s\n' "${FILES[@]}"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  (dry-run — nothing written)"
    continue
  fi

  BASE="$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  BASE="${BASE:-main}"
  BRANCH="chore/$DAY-pm-churn-sweep"

  # Refuse to build onto the branch the shared tree currently has checked out — that is
  # commit-paths.sh's exit 3, but catching it here gives a clearer message.
  CUR="$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ "$BRANCH" == "$CUR" ]]; then
    echo "  ERROR: $BRANCH is checked out in this worktree — skipping." >&2; RC=1; continue
  fi

  # Prefer an up-to-date parent; fall back to local base, then HEAD, if origin is unreachable.
  BASE_REF="origin/$BASE"
  git -C "$REPO" rev-parse -q --verify "$BASE_REF" >/dev/null 2>&1 || BASE_REF="$BASE"
  git -C "$REPO" rev-parse -q --verify "$BASE_REF" >/dev/null 2>&1 || BASE_REF=""

  declare -a CP_ARGS=(--repo "$REPO" --branch "$BRANCH"
                      --message "chore(pm): sweep project churn files")
  [[ -n "$BASE_REF" ]] && CP_ARGS+=(--base "$BASE_REF")
  # Loss guards on the two genuinely append-only files.
  for f in "${FILES[@]}"; do
    case "$f" in
      *meetings.jsonl|*LAST-SESSION.md) CP_ARGS+=(--append-only "$f") ;;
    esac
  done
  CP_ARGS+=(--paths "${FILES[@]}")

  SHA="$("$COMMIT_PATHS" "${CP_ARGS[@]}")"
  CP_RC=$?
  if [[ "$CP_RC" -ne 0 ]]; then
    echo "  ERROR: commit-paths.sh failed (rc=$CP_RC) — nothing written for this repo." >&2
    RC=1; continue
  fi
  if [[ -z "$SHA" ]]; then
    echo "  no-op: tree already matches $BRANCH tip — nothing to commit."
    continue
  fi
  echo "  committed $SHA on $BRANCH"

  [[ "$SHIP" -eq 1 ]] || { echo "  (local only — pass --ship to PR it)"; continue; }
  if ! command -v gh >/dev/null 2>&1; then
    echo "  --ship requested but gh is not installed — leaving the branch local." >&2; continue
  fi
  if ! git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
    echo "  --ship requested but no origin remote — leaving the branch local." >&2; continue
  fi
  git -C "$REPO" push -q origin "$BRANCH" || { echo "  push failed" >&2; RC=1; continue; }

  # gh resolves its repo from CWD, which is NOT $REPO here — pass --repo explicitly so a
  # sweep run from anywhere targets the right remote.
  NWO="$(cd "$REPO" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"
  if [[ -z "$NWO" ]]; then
    echo "  could not resolve the GitHub repo — branch pushed, merge $BRANCH by hand." >&2
    RC=1; continue
  fi
  URL="$(gh pr create --repo "$NWO" --base "$BASE" --head "$BRANCH" \
          --title "chore(pm): sweep project churn files" \
          --body "Daily PM churn sweep: commits CALENDAR.*, meetings.jsonl, .pm/ and LAST-SESSION.md across registered project roots. These are excluded from /pm-end's per-session commit by design; this sweep owns them. Built with lib/commit-paths.sh (frozen-HEAD) — the shared worktree was never touched." \
          2>/dev/null)" || echo "  pr create failed (a PR may already exist for $BRANCH)" >&2
  [[ -n "${URL:-}" ]] && echo "  PR: $URL"
  if gh pr merge "$BRANCH" --repo "$NWO" --squash --delete-branch >/dev/null 2>&1; then
    echo "  merged + branch deleted"
  else
    echo "  merge deferred — merge $BRANCH by hand" >&2
  fi
done < <(cut -f1 "$PAIRS" | sort -u)

exit "$RC"
