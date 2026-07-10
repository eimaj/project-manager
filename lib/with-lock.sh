#!/usr/bin/env bash
#
# with-lock.sh — reusable atomic mkdir lock (retry -> stale-break -> fail loud).
#
# Source it, then run a critical section under the lock:
#   source "<framework_root>/lib/with-lock.sh"
#   with_lock <lock_dir> <command...>     # runs <command...> while holding <lock_dir>
#
# Semantics mirror the proven inline lock in handoff-write.sh / scaffold.sh:
#   - mkdir is atomic and portable — it is the lock acquire.
#   - short retry (~5s at 50 x 0.1s) before giving up on a contended lock.
#   - a lock older than PM_LOCK_STALE_AFTER (default 30s) is assumed to be left by a
#     crashed / kill -9'd run: break it (rmdir) and retry once (~1s at 10 x 0.1s).
#   - on give-up we FAIL LOUD (return non-zero) and do NOT run the command, rather
#     than proceed unlocked and silently lose-update shared state.
#   - the lock is released as soon as the command returns.
#
# Design note: standalone scripts (handoff-write.sh, scaffold.sh) release via a
# script-level `trap ... EXIT` because they ARE the whole process. A sourced helper
# must NOT install an EXIT trap — it would clobber the caller's own trap. So with_lock
# releases inline right after the command returns; the 30s stale-break is the
# crash-recovery backstop (a caller killed mid-critical-section leaves a lock that the
# next run breaks after PM_LOCK_STALE_AFTER), preserving the same guarantee the
# standalone scripts rely on. Preserve the BSD/GNU dual `stat` form and 30s default.

PM_LOCK_STALE_AFTER="${PM_LOCK_STALE_AFTER:-30}"

_wl_lock_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

_wl_acquire() {  # _wl_acquire <lockdir> <tries>
  local lock="$1" tries="$2" i
  for ((i=0; i<tries; i++)); do
    if mkdir "$lock" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}

with_lock() {  # with_lock <lockdir> <command...>
  local lock="$1"; shift
  [[ -n "$lock" && $# -gt 0 ]] || { echo "with-lock: usage: with_lock <lockdir> <command...>" >&2; return 2; }
  local locked=""
  if _wl_acquire "$lock" 50; then
    locked=1
  else
    local now mt age
    now="$(date +%s)"
    mt="$(_wl_lock_mtime "$lock")"; mt="${mt:-$now}"
    age=$(( now - mt ))
    if (( age >= PM_LOCK_STALE_AFTER )); then
      echo "with-lock: breaking stale lock (age ${age}s) at $lock" >&2
      rmdir "$lock" 2>/dev/null || true
      _wl_acquire "$lock" 10 && locked=1
    fi
  fi
  [[ -n "$locked" ]] || { echo "with-lock: could not acquire $lock (held by a live run?); aborting to avoid a lost update." >&2; return 1; }
  # Release on return (function-scoped; caller keeps its own EXIT trap, if any).
  local rc=0
  "$@" || rc=$?
  rmdir "$lock" 2>/dev/null || true
  return "$rc"
}
