#!/usr/bin/env bash
#
# handoff-write.sh — update one session's handoff block in <root>/LAST-SESSION.md.
#
# Per-session handoffs: each /pm-end replaces ONLY its own session's block and
# preserves blocks written by other concurrent sessions on the same project, so
# two sessions on the same project never clobber each other's "where I left off".
#
# Usage:
#   handoff-write.sh --root <root> --session <sid> [--name <project name>]
#   The block BODY (markdown) is read from stdin.
#
# Block layout in the file:
#   <!-- PM:SESSION <sid> START -->
#   ## Session <sid> — <YYYY-MM-DD HH:MM>
#   <body>
#   <!-- PM:SESSION <sid> END -->
#
# Backward-compat: a pre-existing marker-less LAST-SESSION.md is wrapped once as a
# single "legacy" block so its content survives the first per-session write.
#
# Concurrency: a mkdir-based lock (atomic, portable) guards the read-modify-write
# so two simultaneous /pm-end runs cannot lose-update.
#
# Tool-agnostic: this helper only edits a markdown file. It names no meeting source,
# tracker, or logger — those live behind capability slots resolved elsewhere.

set -euo pipefail

ROOT=""; SID=""; NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)    ROOT="$2"; shift 2 ;;
    --session) SID="$2"; shift 2 ;;
    --name)    NAME="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "handoff-write.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$ROOT" && -n "$SID" ]] || { echo "handoff-write.sh: --root and --session are required" >&2; exit 2; }
[[ -d "$ROOT" ]] || { echo "handoff-write.sh: root does not exist: $ROOT" >&2; exit 2; }

FILE="$ROOT/LAST-SESSION.md"
BODY="$(cat)"                          # block body from stdin
# Invariant: body content can NEVER be mistaken for a structural marker. A body line
# that is itself a full-line PM:SESSION START/END marker would otherwise be read as a
# block boundary on the next rewrite and corrupt the file. Neutralize it losslessly by
# breaking the PM:SESSION token with an HTML entity for the colon — it still renders
# identically (the line is an HTML comment either way) but no longer matches the
# structural pattern the awk pass anchors on.
BODY="$(printf '%s' "$BODY" | sed -E 's/^(<!-- )PM:SESSION( .* (START|END) -->)$/\1PM\&#58;SESSION\2/')"
TS="$(date '+%Y-%m-%d %H:%M')"
START="<!-- PM:SESSION ${SID} START -->"
END="<!-- PM:SESSION ${SID} END -->"

# ---- lock (mkdir is atomic; short retry, then stale-break, then fail loud) ----
# A crashed / kill -9'd run can leave the mkdir lock behind forever, so if acquisition
# keeps failing we check the lock's age and break a lock older than STALE_AFTER, then
# retry once. If we still cannot acquire, we FAIL LOUDLY (non-zero) rather than proceed
# unlocked and silently lose-update another session's block.
mkdir -p "$ROOT/.pm"
LOCK="$ROOT/.pm/.handoff.lock"
STALE_AFTER=30

lock_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
acquire_lock() {  # acquire_lock <tries>
  local tries="$1" i
  for ((i=0; i<tries; i++)); do
    if mkdir "$LOCK" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}

locked=""
if acquire_lock 50; then
  locked=1
else
  now="$(date +%s)"
  mt="$(lock_mtime "$LOCK")"; mt="${mt:-$now}"
  age=$(( now - mt ))
  if (( age >= STALE_AFTER )); then
    echo "handoff-write.sh: breaking stale lock (age ${age}s) at $LOCK" >&2
    rmdir "$LOCK" 2>/dev/null || true
    acquire_lock 10 && locked=1
  fi
fi
if [[ -n "$locked" ]]; then
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
else
  echo "handoff-write.sh: could not acquire lock at $LOCK (held by a live run?); aborting to avoid a lost update." >&2
  exit 1
fi

# ---- ensure the file exists with a header; wrap legacy content once -----------
if [[ ! -f "$FILE" ]]; then
  printf '# %s — Last Session\n\n> Per-session handoffs. Each /pm-end updates only its own session block.\n' \
    "${NAME:-Project}" > "$FILE"
elif ! grep -q 'PM:SESSION' "$FILE"; then
  OLD="$(cat "$FILE")"
  {
    printf '# %s — Last Session\n\n> Per-session handoffs. Each /pm-end updates only its own session block.\n\n' \
      "${NAME:-Project}"
    printf '<!-- PM:SESSION legacy START -->\n%s\n<!-- PM:SESSION legacy END -->\n' "$OLD"
  } > "$FILE"
fi

# ---- rebuild: drop this session's existing block, then append the new one -----
TMP="$(mktemp)"
awk -v s="$START" -v e="$END" '
  # Drop only THIS session block (between its START and END), then re-append below.
  # Structural markers are matched as FULL LINES only (anchored ^...$); a marker-looking
  # string embedded mid-line is body content, never a boundary. Body lines that would
  # otherwise be full-line markers are neutralized before write (see BODY sed above), so
  # this pass can only ever key on real structural markers.
  # Safety against a malformed file: while skipping, ANY other session boundary
  # marker (a PM:SESSION ... START/END line that is not our own END) also ends the
  # skip and is itself printed. So a START whose matching END was lost can drop at
  # most its own block up to the next block boundary — it can never run to EOF and
  # silently truncate the rest of the file.
  $0==s { skip=1; next }
  skip && $0==e { skip=0; next }
  skip && /^<!-- PM:SESSION .* (START|END) -->$/ { skip=0; print; next }
  !skip { print }
' "$FILE" > "$TMP"
printf '\n%s\n## Session %s — %s\n\n%s\n%s\n' "$START" "$SID" "$TS" "$BODY" "$END" >> "$TMP"
mv "$TMP" "$FILE"

echo "handoff-write.sh: updated block for session $SID in $FILE"
