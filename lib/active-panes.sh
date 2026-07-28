#!/usr/bin/env bash
# active-panes.sh — which OTHER Claude Code sessions are currently open on a project.
#
# The per-session marker dir already IS the active-session index: sessions/<sid> holds the
# project root that session opened. This helper inverts the lookup (given a root, which
# sessions?) and reconciles the two things a marker alone cannot tell you:
#
#   CLOSED — /pm-end drops a sidecar at sessions/.closed/<sid>. The marker itself is left
#            INTACT so a later /pm-status in that same pane still resolves its project;
#            only how sibling panes see it changes. /pm-start clears the sidecar on reopen.
#   DEAD   — a pane can crash or be killed without ever running /pm-end, and markers are
#            immortal until pruned, so presence proves nothing. Liveness is therefore
#            evidence-based: a Claude Code transcript for that sid touched within
#            --live-mins (default 240). Override the transcript root with PM_CC_PROJECTS.
#
# TOOL-AGNOSTIC BY DESIGN. This answers WHO is on the project, never WHAT they did. Activity
# belongs to whichever `tool:logs` provider the user configured, and the pm-* skills resolve
# it behind pm_tool_defined. Do not teach this file about any logger.
#
# Usage:
#   active-panes.sh --root <project_root> [--live-mins N] [--json] [--include-self]
#
# Output (table, one row per live pane):  <sid>  <idle>  <opened>
#   idle    minutes since that session's transcript was last touched
#   opened  marker mtime (when that pane ran /pm-start)
# --json emits one JSON object per line: {sid, idle_mins, opened, root, self}
#
# Exit: 0 always (an empty list is a normal answer, not an error).

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSIONS_DIR="${PM_SESSIONS_DIR:-$(cd -P "$HERE/.." && pwd)/sessions}"
CC_PROJECTS="${PM_CC_PROJECTS:-$HOME/.claude/projects}"
ROOT=""; LIVE_MINS=240; FORMAT=table; INCLUDE_SELF=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root) shift; ROOT="${1:?--root needs a value}" ;;
    --root=*) ROOT="${1#*=}" ;;
    --live-mins) shift; LIVE_MINS="${1:?--live-mins needs a value}" ;;
    --live-mins=*) LIVE_MINS="${1#*=}" ;;
    --json) FORMAT=json ;;
    --include-self) INCLUDE_SELF=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "active-panes.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$ROOT" ] || { echo "active-panes.sh: --root is required" >&2; exit 2; }
[ -d "$SESSIONS_DIR" ] || exit 0

# Normalize the root so a marker written from a different cwd still matches.
ROOT="$(cd -P "$ROOT" 2>/dev/null && pwd)" || true
[ -n "$ROOT" ] || exit 0

SELF="$("$HERE/session.sh" 2>/dev/null || true)"

mtime_of()     { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
transcript_of(){ find "$CC_PROJECTS" -maxdepth 2 -name "${1}.jsonl" -print -quit 2>/dev/null; }
fmt_ts()       { date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null \
                 || date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null; }

NOW="$(date +%s)"
rows=""

while IFS= read -r marker; do
  [ -n "$marker" ] || continue
  sid="$(basename "$marker")"
  [ "$INCLUDE_SELF" -eq 1 ] || [ "$sid" != "$SELF" ] || continue
  # Same project? Compare resolved paths, tolerating a trailing slash.
  mroot="$(head -1 "$marker" 2>/dev/null)"; mroot="${mroot%/}"
  [ "$mroot" = "$ROOT" ] || continue
  # Closed by /pm-end?
  [ -e "$SESSIONS_DIR/.closed/$sid" ] && continue
  # Live? Requires a transcript touched inside the window.
  t="$(transcript_of "$sid")"; [ -n "$t" ] || continue
  tm="$(mtime_of "$t")"; [ -n "$tm" ] || continue
  idle=$(( (NOW - tm) / 60 ))
  [ "$idle" -le "$LIVE_MINS" ] || continue
  om="$(mtime_of "$marker")"; om="${om:-$tm}"
  rows="${rows}${sid}	${idle}	$(fmt_ts "$om")	$([ "$sid" = "$SELF" ] && echo true || echo false)"$'\n'
done < <(find "$SESSIONS_DIR" -maxdepth 1 -type f -print 2>/dev/null | sort)

rows="$(printf '%s' "$rows" | sed '/^$/d')"
[ -n "$rows" ] || exit 0

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$rows" | while IFS=$'\t' read -r sid idle opened isself; do
    jq -nc --arg sid "$sid" --arg opened "$opened" --arg root "$ROOT" \
           --argjson idle "$idle" --argjson self "$isself" \
      '{sid:$sid, idle_mins:$idle, opened:$opened, root:$root, self:$self}'
  done
  exit 0
fi

printf '%-38s %-6s %s\n' "SESSION" "IDLE" "OPENED"
printf '%s\n' "$rows" | sort -t$'\t' -k2 -n | while IFS=$'\t' read -r sid idle opened isself; do
  printf '%-38s %-6s %s\n' "$sid" "${idle}m" "$opened"
done
