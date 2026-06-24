#!/usr/bin/env bash
# lib/session.sh — resolve a stable per-session marker id for the PM framework.
#
# CLAUDE_SESSION_ID is frequently unset in the Bash-tool shell, so fall back to a
# terminal/multiplexer session pid if present, then the parent shell pid. Echoes the
# id on stdout. Used by pm-start (write the marker), pm-status / pm-end (read it) so
# all three agree on which project is active in this session.
echo "${CLAUDE_SESSION_ID:-${PM_SESSION_PID:-${TERM_SESSION_ID:-shell-$PPID}}}"
