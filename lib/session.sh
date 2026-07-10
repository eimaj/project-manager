#!/usr/bin/env bash
# lib/session.sh — resolve a stable per-session marker id for the PM framework.
#
# Claude Code exports CLAUDE_CODE_SESSION_ID (a stable per-session UUID); prefer it. The
# older CLAUDE_SESSION_ID is kept as a secondary but is frequently unset, so fall back
# through a chain of increasingly-weak anchors. Absent any session env var, continuity
# relies on a stable *controlling terminal*: each Bash-tool command spawns a fresh parent
# shell, so $PPID is unstable, but the tty is constant for the session — prefer it.
# Resolution order: CLAUDE_CODE_SESSION_ID → CLAUDE_SESSION_ID → PM_SESSION_PID → TERM_SESSION_ID → tty → shell-$PPID.
# Echoes exactly one id on stdout. Used by pm-start (write the marker), pm-status / pm-end
# (read it) so all three agree on which project is active in this session.

sid="${CLAUDE_CODE_SESSION_ID:-}"
[[ -z "$sid" ]] && sid="${CLAUDE_SESSION_ID:-}"
[[ -z "$sid" ]] && sid="${PM_SESSION_PID:-}"
[[ -z "$sid" ]] && sid="${TERM_SESSION_ID:-}"
if [[ -z "$sid" ]]; then
  # Controlling-terminal anchor: trim whitespace, sanitize '/' → '-'. Skip when the
  # process has no tty (batch/CI: ps prints empty or '?'/'??').
  tty="$(ps -o tty= -p $$ 2>/dev/null | tr -d '[:space:]')"
  if [[ -n "$tty" && "$tty" != "?" && "$tty" != "??" ]]; then
    sid="tty-${tty//\//-}"
  fi
fi
[[ -z "$sid" ]] && sid="shell-$PPID"
echo "$sid"
