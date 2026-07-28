#!/usr/bin/env bash
# Prune stale PM session markers in <framework_root>/sessions/.
#
# A marker is a file named <session-id>; its content is a project-root path.
# pm-start writes one per Claude Code session and NOTHING deletes it, so the
# directory grows by one file per session forever. This helper reclaims them.
#
# What it does:
#   - removes markers older than N days (default 14)
#   - NEVER removes the marker for the current resolved session id
#   - NEVER removes a marker whose session is still LIVE (see below)
#
# What it deliberately does NOT do: dedupe by project root. An earlier version kept
# only the newest marker per root and deleted the rest as "duplicates". That is wrong
# for concurrent panes — several sessions legitimately hold their own marker for the
# SAME project at the same time, and the dedupe pass would delete the live ones,
# breaking their /pm-status and /pm-end. Markers are per SESSION, not per project;
# there is no such thing as a duplicate. Age is the only correct trigger.
#
# Liveness: Claude Code writes a transcript per session at
# ~/.claude/projects/<cwd-slug>/<session-id>.jsonl and touches it as the session runs.
# A marker whose transcript was modified within --live-mins (default 1440) is protected
# regardless of age, so a long-running pane is never pruned out from under itself.
# Override the transcript root with PM_CC_PROJECTS (e.g. for tests).
#
# Safety: DRY-RUN by default (prints what it would delete). Pass --apply to act.
# Deletes via `trash` when available (never `rm -rf`); falls back to `rm -f`.
#
# Usage:
#   prune-markers.sh [--apply] [--days N] [--live-mins M] [--dir <sessions_dir>]
#
# Env: PM_SESSIONS_DIR (marker dir), PM_CC_PROJECTS (transcript root),
#      PM_NO_TRASH=1 (use rm instead of trash — non-interactive runs).
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${PM_SESSIONS_DIR:-$(cd -P "$HERE/.." && pwd)/sessions}"
CC_PROJECTS="${PM_CC_PROJECTS:-$HOME/.claude/projects}"
DAYS=14
LIVE_MINS=1440
APPLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --days) shift; DAYS="${1:?--days needs a value}" ;;
    --days=*) DAYS="${1#*=}" ;;
    --live-mins) shift; LIVE_MINS="${1:?--live-mins needs a value}" ;;
    --live-mins=*) LIVE_MINS="${1#*=}" ;;
    --dir) shift; DIR="${1:?--dir needs a value}" ;;
    --dir=*) DIR="${1#*=}" ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -d "$DIR" ] || { echo "no marker dir: $DIR"; exit 0; }

SELF="$("$HERE/session.sh" 2>/dev/null || true)"
echo "marker dir:      $DIR"
echo "current session: ${SELF:-<unresolved>} (protected)"
echo "mode:            $([ "$APPLY" -eq 1 ] && echo APPLY || echo DRY-RUN)   retention: ${DAYS}d   live-window: ${LIVE_MINS}m"
echo

# sid_live <sid> — 0 when a Claude Code transcript for <sid> was touched within the
# live window. Cheap: one bounded find, first hit wins.
sid_live() {
  local sid="$1"
  [ -d "$CC_PROJECTS" ] || return 1
  [ -n "$(find "$CC_PROJECTS" -maxdepth 2 -name "${sid}.jsonl" -mmin "-${LIVE_MINS}" -print -quit 2>/dev/null)" ]
}

del() {  # del <path> <reason>
  local f="$1" reason="$2"
  echo "DELETE  $(basename "$f")  ($reason)"
  if [ "$APPLY" -eq 1 ]; then
    # Prefer `trash` (recoverable) interactively. PM_NO_TRASH=1 forces a plain rm for
    # non-interactive runs (CI, tests) where filling the user's Trash is not wanted.
    if [ -z "${PM_NO_TRASH:-}" ] && command -v trash >/dev/null 2>&1; then trash "$f"; else rm -f "$f"; fi
  fi
}

# mtime_of <path> — epoch seconds, BSD then GNU (same dual form with-lock.sh uses).
mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

removed=0 kept=0
cutoff=$(( $(date +%s) - DAYS*86400 ))

while IFS= read -r path; do
  [ -n "$path" ] || continue
  mtime="$(mtime_of "$path")"; [ -n "$mtime" ] || continue
  base="$(basename "$path")"
  root="$(cat "$path" 2>/dev/null)"

  if [ "$base" = "$SELF" ]; then
    kept=$((kept+1)); echo "KEEP    $base  (current session)"; continue
  fi
  if sid_live "$base"; then
    kept=$((kept+1)); echo "KEEP    $base  (session live within ${LIVE_MINS}m)"; continue
  fi
  if [ "$mtime" -lt "$cutoff" ]; then
    del "$path" "older than ${DAYS}d"; removed=$((removed+1)); continue
  fi

  kept=$((kept+1)); echo "KEEP    $base  ($root)"
done < <(find "$DIR" -maxdepth 1 -type f -print 2>/dev/null | sort)

echo
echo "summary: kept=$kept  removed=$removed  ($([ "$APPLY" -eq 1 ] && echo applied || echo dry-run))"
