#!/usr/bin/env bash
# lib/session.sh — resolve a stable per-session marker id for the PM framework.
#
# Claude Code exports CLAUDE_CODE_SESSION_ID (a stable per-session UUID); prefer it. The
# older CLAUDE_SESSION_ID is kept as a secondary but is frequently unset, so fall back
# through a chain of increasingly-weak anchors.
#
# On the anchors, MEASURED rather than assumed (2026-07-28, Claude Code 2.1.220 in herdr):
#   - $PPID is the long-lived `claude` process itself ($PPID == $CLAUDE_PID), so it is
#     STABLE for the whole session — not per-Bash-call as an earlier version of this
#     comment claimed.
#   - `ps -o tty= -p $$` returns "??": Bash-tool commands run with NO controlling terminal,
#     so the tty branch never fires on this harness. It is kept only for shells that do
#     have one (a human running these helpers from a real terminal).
# The tty branch is therefore effectively dead under Claude Code and ppid- is what
# pm_session_anchor actually returns. Do not build on the tty form without re-measuring.
#
# Resolution order: CLAUDE_CODE_SESSION_ID → CLAUDE_SESSION_ID → PM_SESSION_PID → TERM_SESSION_ID → minted-id → tty → shell-$PPID.
# Echoes exactly one id on stdout. Used by pm-start (write the marker), pm-status / pm-end
# (read it) so all three agree on which project is active in this session.
#
# Pure resolver: it only READS state and echoes an id. It NEVER creates the mint file —
# that is pm-start's job (see templates/pm-start). Here the mint step is a read-only
# lookup of a UUID pm-start previously persisted for this shell's anchor.
#
# This file is safe to source: it defines helpers (pm_session_anchor, pm_framework_root,
# pm_session_id) and only auto-echoes an id when EXECUTED directly. pm-start sources it so
# the anchor derivation stays identical on both sides (no drift).

# Most stable anchor for this shell, used to key the mint file: controlling tty (sanitized),
# else $PPID. Override with PM_SESSION_ANCHOR (testing / explicit pinning).
pm_session_anchor() {
  if [[ -n "${PM_SESSION_ANCHOR:-}" ]]; then
    printf '%s\n' "$PM_SESSION_ANCHOR"; return 0
  fi
  local tty
  tty="$(ps -o tty= -p $$ 2>/dev/null | tr -d '[:space:]')"
  if [[ -n "$tty" && "$tty" != "?" && "$tty" != "??" ]]; then
    printf 'tty-%s\n' "${tty//\//-}"
  else
    printf 'ppid-%s\n' "$PPID"
  fi
}

# Framework root: PM_FRAMEWORK_ROOT if set, else the parent of this script's dir
# (<framework_root>/lib/session.sh). The mint dir lives at <framework_root>/sessions/.mint.
pm_framework_root() {
  if [[ -n "${PM_FRAMEWORK_ROOT:-}" ]]; then
    printf '%s\n' "$PM_FRAMEWORK_ROOT"; return 0
  fi
  local src="${BASH_SOURCE[0]}" dir
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  (cd -P "$dir/.." && pwd)
}

# Resolve and echo the session id per the documented chain.
pm_session_id() {
  local sid=""
  sid="${CLAUDE_CODE_SESSION_ID:-}"
  [[ -z "$sid" ]] && sid="${CLAUDE_SESSION_ID:-}"
  [[ -z "$sid" ]] && sid="${PM_SESSION_PID:-}"
  [[ -z "$sid" ]] && sid="${TERM_SESSION_ID:-}"
  if [[ -z "$sid" ]]; then
    # Minted-id lookup (read-only): a UUID pm-start persisted for this anchor, if any.
    local mintfile
    mintfile="$(pm_framework_root)/sessions/.mint/$(pm_session_anchor)"
    [[ -r "$mintfile" ]] && sid="$(cat "$mintfile" 2>/dev/null)"
  fi
  if [[ -z "$sid" ]]; then
    # Controlling-terminal anchor: trim whitespace, sanitize '/' → '-'. Skip when the
    # process has no tty (batch/CI: ps prints empty or '?'/'??').
    local tty
    tty="$(ps -o tty= -p $$ 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "$tty" && "$tty" != "?" && "$tty" != "??" ]]; then
      sid="tty-${tty//\//-}"
    fi
  fi
  [[ -z "$sid" ]] && sid="shell-$PPID"
  printf '%s\n' "$sid"
}

# Auto-echo the id only when executed directly, not when sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  pm_session_id
fi
